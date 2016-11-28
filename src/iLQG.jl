import Base: length
type  Trace
    iter::Int64
    λ::Float64
    dλ::Float64
    cost::Float64
    alpha::Float64
    grad_norm::Float64
    improvement::Float64
    reduc_ratio::Float64
    time_derivs::Float64
    time_forward::Float64
    time_backward::Float64
    Trace() = new(0,0.,0.,0.,0.,0.,0.,0.,0.,0.,0.)
end

type GaussianDist{P}
    T::Int
    n::Int
    m::Int
    fx::Array{P,3}
    fu::Array{P,3}
    Σ::Array{P,3}
    μx::Array{P,2}
    μu::Array{P,2}
end

type GaussianTrajDist{P}
    policy::GaussianDist{P}
    dynamics::GaussianDist{P}
end


include("klutils.jl")

"""
iLQG - solve the deterministic finite-horizon optimal control problem.

minimize sum_i cost(x[:,i],u[:,i]) + cost(x[:,end])
s.t.  x[:,i+1] = f(x[:,i],u[:,i])

Inputs
======
`f, fT, df`

1) step:
`xnew,cost = f(x,u,i)` is called during the forward pass.
Here the state x and control u are vectors: size(x)==(n,),
size(u)==(m,). The time index `i` is a scalar.


2) final:
`cost = fT(x)` is called at the end the forward pass to compute
the final cost.

3) derivatives:
`fx,fu,fxx,fxu,fuu,cx,cu,cxx,cxu,cuu = df(x,u)` computes the
derivatives along a trajectory. In this case size(x)==(n, N) where N
is the trajectory length. size(u)==(m, N). The time indexes are I=(1:N).
Dimensions match the variable names e.g. size(fxu)==(n, n, m, N)
If cost function or system is time invariant, the dimension of the corresponding
derivatives can be reduced by dropping the time dimension

`x0` - The initial state from which to solve the control problem.
Should be a column vector. If a pre-rolled trajectory is available
then size(x0)==(n, N) can be provided and cost set accordingly.

`u0` - The initial control sequence. A matrix of size(u0)==(m, N)
where m is the dimension of the control and N is the number of state
transitions.

Outputs
=======
`x` - the optimal state trajectory found by the algorithm.
size(x)==(n, N)

`u` - the optimal open-loop control sequence.
size(u)==(m, N)

`L` - the optimal closed loop control gains. These gains multiply the
deviation of a simulated trajectory from the nominal trajectory x.
size(L)==(m, n N)

`Vx` - the gradient of the cost-to-go. size(Vx)==(n, N)

`Vxx` - the Hessian of the cost-to-go. size(Vxx)==(n, n N)

`cost` - the costs along the trajectory. size(cost)==(1, N)
the cost-to-go is V = fliplr(cumsum(fliplr(cost)))

`λ` - the final value of the regularization parameter

`trace` - a trace of various convergence-related values. One row for each
iteration, the columns of trace are
`[iter λ alpha g_norm dcost z sum(cost) dλ]`
see below for details.

`timing` - timing information
---------------------- user-adjustable parameters ------------------------
defaults

`lims`,           [],            control limits
`Alpha`,          logspace(0,-3,11), backtracking coefficients
`tolFun`,         1e-7,          reduction exit criterion
`tolGrad`,        1e-4,          gradient exit criterion
`maxIter`,        500,           maximum iterations
`λ`,         1,             initial value for λ
`dλ`,        1,             initial value for dλ
`λFactor`,   1.6,           λ scaling factor
`λMax`,      1e10,          λ maximum value
`λMin`,      1e-6,          below this value λ = 0
`regType`,        1,             regularization type 1: q_uu+λ*I 2: V_xx+λ*I
`zMin`,           0,             minimal accepted reduction ratio
`diffFn`,         -,             user-defined diff for sub-space optimization
`plot`,           1,             0: no  k>0: every k iters k<0: every k iters, with derivs window
`verbosity`,      2,             0: no  1: final 2: iter 3: iter, detailed
`plotFn`,         x->0,          user-defined graphics callback
`cost`,           [],            initial cost for pre-rolled trajectory

This code consists of a port and extension of a MATLAB library provided by the autors of
`   INPROCEEDINGS{author={Tassa, Y. and Mansard, N. and Todorov, E.},
booktitle={Robotics and Automation (ICRA), 2014 IEEE International Conference on},
title={Control-Limited Differential Dynamic Programming},
year={2014}, month={May}, doi={10.1109/ICRA.2014.6907001}}`
"""
function iLQG(f,fT,df, x0, u0;
    lims      = [],
    Alpha     = logspace(0,-3,11),
    tolFun    = 1e-7,
    tolGrad   = 1e-4,
    maxIter   = 500,
    λ         = 1,
    dλ        = 1,
    λFactor   = 1.6,
    λMax      = 1e10,
    λMin      = 1e-6,
    regType   = 1,
    zMin      = 0,
    diffFn    = -,
    plot      = 1,
    verbosity = 2,
    plotFn    = x->0,
    cost      = [],
    kl_step   = 0,
    traj_prev
    )
    debug("Entering iLQG")

    # --- initial sizes and controls
    n   = size(x0, 1)          # dimension of state vector
    m   = size(u0, 1)          # dimension of control vector
    N   = size(u0, 2)          # number of state transitions
    u   = u0                   # initial control sequence

    # --- initialize trace data structure
    trace = [Trace() for i in 1:min( maxIter+1,1e6)]
    trace[1].iter = 1
    trace[1].λ = λ
    trace[1].dλ = dλ

    function calc_η(xnew,unew,sigmanew,η)
        break_ = false
        if kl_step > 0
            div = kl_div(xnew,unew,sigmanew, traj_new, traj_prev)
            con = div - kl_step
            # Convergence check - constraint satisfaction.
            if (abs(con) < 0.1*kl_step) # allow some small constrain violation
                debug(@sprintf("KL: %12.7f / %12.7f, converged",  div, kl_step))
                break_ = true
            end
            if con < 0 # η was too big.
                max_η = η
                geom = √(min_η*max_η)  # Geometric mean.
                new_η = max(geom, 0.1*max_η)
                debug(@sprintf("KL: %12.7f / %12.7f, η too big, new η: %12.7f",  div, kl_step, new_η))
            else # η was too small.
                min_η = η
                geom = √(min_η*max_η)  # Geometric mean.
                new_η = min(geom, 10.0*min_η)
                debug(@sprintf("KL: %12.7f / %12.7f, η too small, new η: %12.7f",  div, kl_step, new_η))
            end
            return new_η, break_
        end
        return 1., break_
    end

    # --- initial trajectory
    debug("Setting up initial trajectory")
    if size(x0,2) == 1 # only initial state provided
        diverge = true
        for alpha =  Alpha
            debug("# test different backtracing parameters alpha and break loop when first succeeds")
            x,un,cost,_ = forward_pass(traj_new,x0[:,1],alpha*u,[],1,f,fT, lims,diffFn)
            debug("# simplistic divergence test")
            if all(abs(x[:]) .< 1e8)
                u = un
                diverge = false
                break
            end
        end
    elseif size(x0,2) == N
        debug("# pre-rolled initial forward pass, initial traj provided, e.g. from demonstration")
        x        = x0
        diverge  = false
        isempty(cost) && error("Initial trajectory supplied, initial cost must also be supplied")
    else
        error("pre-rolled initial trajectory must be of correct length (size(x0,2) == N)")
    end

    trace[1].cost = sum(cost)

    # user plotting
    #     plotFn(x)

    if diverge
        Vx=Vxx   = NaN
        L        = zeros(m,n,N)
        cost     = []
        trace    = trace[1]
        if verbosity > 0
            @printf("\nEXIT: Initial control sequence caused divergence\n")
        end
        return
    end

    # constants, timers, counters
    flgChange   = true
    dcost       = 0.
    z           = 0
    expected    = 0.
    print_head  = 10 # print headings every print_head lines
    last_head   = print_head
    g_norm      = Vector{Float64}()
    t_start     = time()
    verbosity > 0 && @printf("\n---------- begin iLQG ----------\n")

    iter = acceptedIter = 1
    while acceptedIter <= maxIter
        trace[iter].iter = iter
        # ====== STEP 1: differentiate dynamics and cost along new trajectory
        if flgChange
            tic()
            fx,fu,fxx,fxu,fuu,cx,cu,cxx,cxu,cuu = df(x, u)
            trace[iter].time_derivs = toq()
            flgChange   = false
        end

        # Determine what kind of system we are dealing with
        linearsys = isempty(fxx) && isempty(fxu) && isempty(fuu)
        debug("linear system: $linearsys")

        # ====== STEP 2: backward pass, compute optimal control law and cost-to-go
        backPassDone   = false
        l = Matrix{Float64}()
        dV = Vector{Float64}()
        while !backPassDone
            tic()
            if kl_step > 0
                cxkl,cukl,cxxkl,cuukl,cxukl = dkl(traj_new)
                cx,cu,cxx,cuu,cxu = cx/η+cxkl, cu/η+cukl, cxx/η+cxxkl, cuu/η+cuukl, cxu/η+cxukl
            end
            if linearsys
                diverge, traj_new,Vx, Vxx,dV = back_pass(cx,cu,cxx,cxu,cuu,fx,fu,λ, regType, lims,u)
            else
                diverge, traj_new,Vx, Vxx,dV = back_pass(cx,cu,cxx,cxu,cuu,fx,fu,fxx,fxu,fuu,λ, regType, lims,u)
            end
            k, K = traj_new.μu, traj_new.fx
            trace[iter].time_backward = toq()

            if diverge > 0
                verbosity > 2 && @printf("Cholesky failed at timestep %d.\n",diverge)
                dλ = max(dλ*λFactor, λFactor)
                λ  = max(λ*dλ, λMin)
                if λ >  λMax; break; end
                continue
            end
            backPassDone = true
        end

        #  check for termination due to small gradient
        g_norm = mean(maximum(abs(k) ./ (abs(u)+1),1))
        trace[iter].grad_norm = g_norm
        if g_norm <  tolGrad && λ < 1e-5 && satisfied
            verbosity > 0 && @printf("\nSUCCESS: gradient norm < tolGrad\n")
            break
        end

        # ====== STEP 3: line-search to find new control sequence, trajectory, cost
        fwdPassDone  = false
        xnew,unew,costnew = Matrix{Float64},Matrix{Float64},Vector{Float64}
        if backPassDone
            tic()
            debug("#  serial backtracking line-search")
            for alpha = Alpha
                xnew,unew,costnew,sigmanew = forward_pass(traj_new, x0[:,1] ,u, x,alpha,f,fT, lims, diffFn)
                dcost    = sum(cost) - sum(costnew)
                expected = -alpha*(dV[1] + alpha*dV[2])
                if expected > 0
                    z = dcost/expected
                else
                    z = sign(dcost)
                    warn("negative expected reduction: should not occur")
                end
                if z > zMin
                    fwdPassDone = true
                    break
                end
            end
            alpha = fwdPassDone ? alpha : NaN
            trace[iter].time_forward = toq()
        end

        # ====== STEP 4: accept step (or not), print status
        η, satisfied = calc_η(xnew,unew,sigmanew,η)

        #  print headings
        if verbosity > 1 && last_head == print_head
            last_head = 0
            @printf("%-12s", "iteration     cost    reduction     expected    gradient    log10(λ)\n")
        end

        if fwdPassDone
            if verbosity > 1
                @printf("%-12d%-12.6g%-12.3g%-12.3g%-12.3g%-12.1f\n",
                iter, sum(cost), dcost, expected, g_norm, log10(λ))
                last_head += 1
            end
            dλ = min(dλ / λFactor, 1/ λFactor)
            λ  = λ * dλ

            #  accept changes
            x,u,cost  = xnew,unew,costnew
            flgChange = true
            plotFn(x)
            if dcost < tolFun && satisfied#  terminate ?
                verbosity > 0 &&  @printf("\nSUCCESS: cost change < tolFun\n")
                break
            end
            acceptedIter += 1
        else #  no cost improvement
            dλ  = max(dλ * λFactor,  λFactor)#  increase λ
            λ   = max(λ * dλ,  λMin)
            if verbosity > 1
                @printf("%-12d%-12s%-12.3g%-12.3g%-12.3g%-12.1f\n",
                iter,"NO STEP", dcost, expected, g_norm, log10(λ))
                last_head = last_head+1
            end
            if λ > λMax #  terminate ?
                verbosity > 0 && @printf("\nEXIT: λ > λMax\n")
                break
            end
            push!(trace, Trace())
        end
        #  update trace
        trace[iter].λ           = λ
        trace[iter].dλ          = dλ
        trace[iter].alpha       = alpha
        trace[iter].improvement = dcost
        trace[iter].cost        = sum(cost)
        trace[iter].reduc_ratio = z
        graphics( plot,x,u,cost,K,Vx,Vxx,fx,fxx,fu,fuu,trace[1:iter],0)
        iter += 1
    end

    # save λ/dλ
    trace[iter].λ  = λ
    trace[iter].dλ = dλ

    iter ==  maxIter &&  verbosity > 0 && @printf("\nEXIT: Maximum iterations reached.\n")


    if iter > 1
        if div > kl_step and abs(div - kl_step) > 0.1*kl_step
            warn("KL divergence too high when done")
        end
        diff_t  = [trace[i].time_derivs for i in 1:iter]
        diff_t  = sum(diff_t[!isnan(diff_t)])
        back_t  = [trace[i].time_backward for i in 1:iter]
        back_t  = sum(back_t[!isnan(back_t)])
        fwd_t   = [trace[i].time_forward for i in 1:iter]
        fwd_t   = sum(fwd_t[!isnan(fwd_t)])
        total_t = time()-t_start
        if verbosity > 0
            info = 100/total_t*[diff_t, back_t, fwd_t, (total_t-diff_t-back_t-fwd_t)]
            @printf("\n iterations:   %-3d\n
            final cost:   %-12.7g\n
            final grad:   %-12.7g\n
            final λ: %-12.7e\n
            time / iter:  %-5.0f ms\n
            total time:   %-5.2f seconds, of which\n
            derivs:     %-4.1f%%\n
            back pass:  %-4.1f%%\n
            fwd pass:   %-4.1f%%\n
            other:      %-4.1f%% (graphics etc.)\n =========== end iLQG ===========\n",iter,sum(cost[:]),g_norm,λ,1e3*total_t/iter,total_t,info[1],info[2],info[3],info[4])
        end
    else
        error("Failure: no iterations completed, something is wrong. Try enabling the debug flag in DifferentialDynamicProgramming.jl for verbose printing.")
    end

    return x, u, K, Vx, Vxx, cost, trace

end

function forward_pass(traj_new, x0,u,x,Alpha,f,fT,lims,diff)
    n,m,N     = traj_new.n,traj_new.m,traj_new.T
    xnew      = zeros(n,N)
    xnew[:,1] = x0
    unew      = zeros(m,N)
    cnew      = zeros(N)
    debug("Entering forward_pass loop")
    for i = 1:N
        unew[:,i] = u[:,i]
        if !isempty(du)
            unew[:,i] = unew[:,i] + traj_new.μu[:,i]*Alpha
        end
        if !isempty(K)
            dx = diff(xnew[:,i], x[:,i])
            unew[:,i] = unew[:,i] + traj_new.fx[:,:,i]*dx
        end
        if !isempty(lims)
            unew[:,i] = min(lims[:,2], max(lims[:,1], unew[:,i]))
        end
        xnewi, cnew[i]  = f(xnew[:,i], unew[:,i], i)
        if i < N
            xnew[:,i+1] = xnewi
        end
    end
    # cnew[N+1] = fT(xnew[:,N+1])
    sigmanew = zeros(m+n,m+n,T) # TODO: this function should calculate the covariance matrix as well
    return xnew,unew,cnew,sigmanew
end

macro end_backward_pass()
    quote
        if isempty(lims) || lims[1,1] > lims[1,2]
            debug("#  no control limits: Cholesky decomposition, check for non-PD")
            try
                R = chol(Hermitian(QuuF))
            catch
                diverge  = i
                return diverge, GaussianDist(N,n,m,K,[],Quu,x,u), Vx, Vxx
            end

            debug("#  find control law")
            kK  = -R\(R'\[Qu Qux_reg])
            k_i = kK[:,1]
            K_i = kK[:,2:n+1]
        else
            debug("#  solve Quadratic Program")
            lower = lims[:,1]-u[:,i]
            upper = lims[:,2]-u[:,i]

            k_i,result,R,free = boxQP(QuuF,Qu,lower,upper,k[:,min(i+1,N-1)])
            if result < 1
                diverge  = i
                return diverge, Vx, Vxx, k, K, dV
            end
            K_i  = zeros(m,n)
            if any(free)
                Lfree         = -R\(R'\Qux_reg[free,:])
                K_i[free,:]   = Lfree
            end
        end
        debug("#  update cost-to-go approximation")
        # Qxx         = Hermitian(Qxx)
        dV         = dV + [k_i'Qu; .5*k_i'Quu[:,:,i]*k_i]
        Vx[:,i]    = Qx + K_i'Quu[:,:,i]*k_i + K_i'Qu + Qux'k_i
        Vxx[:,:,i] = Qxx + K_i'Quu[:,:,i]*K_i + K_i'Qux + Qux'K_i
        Vxx[:,:,i] = .5*(Vxx[:,:,i] + Vxx[:,:,i]')

        debug("# save controls/gains")
        k[:,i]   = k_i
        K[:,:,i] = K_i
    end |> esc
end

macro setupQTIC()
    quote
        m   = size(u,1)
        n,N = size(fx,1,3)

        cx  = reshape(cx, (n, N))
        cu  = reshape(cu, (m, N))
        cxx = reshape(cxx, (n, n))
        cxu = reshape(cxu, (n, m))
        cuu = reshape(cuu, (m, m))

        k   = zeros(m,N)
        K   = zeros(m,n,N)
        Vx  = zeros(n,N)
        Vxx = zeros(n,n,N)
        dV  = [0., 0.]

        Vx[:,N]    = cx[:,N]
        Vxx[:,:,N] = cxx
        diverge    = 0
    end |> esc
end

vectens(a,b) = permutedims(sum(a.*b,1), [3 2 1])

function back_pass{T}(cx,cu,cxx::AbstractArray{T,3},cxu,cuu,fx::AbstractArray{T,3},fu,fxx,fxu,fuu,λ,regType,lims,u) # nonlinear time variant

    m,N = size(u)
    n   = size(cx,1)
    cx  = reshape(cx, (n, N))
    cu  = reshape(cu, (m, N))
    cxx = reshape(cxx, (n, n, N))
    cxu = reshape(cxu, (n, m, N))
    cuu = reshape(cuu, (m, m, N))
    k   = zeros(m,N)
    K   = zeros(m,n,N)
    Vx  = zeros(n,N)
    Vxx = zeros(n,n,N)
    dV  = [0., 0.]

    Vx[:,N]     = cx[:,N]
    Vxx[:,:,N]  = cxx[:,:,N]

    diverge  = 0
    for i = N-1:-1:1
        Qu  = cu[:,i]      + fu[:,:,i]'Vx[:,i+1]
        Qx  = cx[:,i]      + fx[:,:,i]'Vx[:,i+1]
        Qux = cxu[:,:,i]'  + fu[:,:,i]'Vxx[:,:,i+1]*fx[:,:,i]
        if !isempty(fxu)
            fxuVx = vectens(Vx[:,i+1],fxu[:,:,:,i])
            Qux   = Qux + fxuVx
        end

        Quu[:,:,i] = cuu[:,:,i]   + fu[:,:,i]'Vxx[:,:,i+1]*fu[:,:,i]
        if !isempty(fuu)
            fuuVx = vectens(Vx[:,i+1],fuu[:,:,:,i])
            Quu[:,:,i]   = Quu[:,:,i] + fuuVx
        end

        Qxx = cxx[:,:,i]   + fx[:,:,i]'Vxx[:,:,i+1]*fx[:,:,i]
        if !isempty(fxx)
            Qxx = Qxx + vectens(Vx[:,i+1],fxx[:,:,:,i])
        end

        Vxx_reg = Vxx[:,:,i+1] + (regType == 2 ? λ*eye(n) : 0)

        Qux_reg = cxu[:,:,i]'   + fu[:,:,i]'Vxx_reg*fx[:,:,i]
        if !isempty(fxu)
            Qux_reg = Qux_reg + fxuVx
        end

        QuuF = cuu[:,:,i]  + fu[:,:,i]'Vxx_reg*fu[:,:,i] + (regType == 1 ? λ*eye(m) : 0)

        if !isempty(fuu)
            QuuF = QuuF + fuuVx
        end

        @end_backward_pass
    end

    return diverge, GaussianDist(N,n,m,K,[],Quu,x,u), Vx, Vxx
end


function back_pass{T}(cx,cu,cxx::AbstractArray{T,2},cxu,cuu,fx::AbstractArray{T,3},fu,fxx,fxu,fuu,λ,regType,lims,u) # quadratic timeinvariant cost, dynamics nonlinear time variant

    @setupQTIC

    for i = N-1:-1:1
        Qu  = cu[:,i]   + fu[:,:,i]'Vx[:,i+1]
        Qx  = cx[:,i]   + fx[:,:,i]'Vx[:,i+1]
        Qux = cxu' + fu[:,:,i]'Vxx[:,:,i+1]*fx[:,:,i]
        if !isempty(fxu)
            fxuVx = vectens(Vx[:,i+1],fxu[:,:,:,i])
            Qux   = Qux + fxuVx
        end

        Quu[:,:,i] = cuu + fu[:,:,i]'Vxx[:,:,i+1]*fu[:,:,i]
        if !isempty(fuu)
            fuuVx = vectens(Vx[:,i+1],fuu[:,:,:,i])
            Quu[:,:,i]   = Quu[:,:,i] + fuuVx
        end

        Qxx = cxx  + fx[:,:,i]'Vxx[:,:,i+1]*fx[:,:,i]
        if !isempty(fxx)
            Qxx = Qxx + vectens(Vx[:,i+1],fxx[:,:,:,i])
        end

        Vxx_reg = Vxx[:,:,i+1] + (regType == 2 ? λ*eye(n) : 0)

        Qux_reg = cxu'   + fu[:,:,i]'Vxx_reg*fx[:,:,i]
        if !isempty(fxu)
            Qux_reg = Qux_reg + fxuVx
        end

        QuuF = cuu  + fu[:,:,i]'Vxx_reg*fu[:,:,i] + (regType == 1 ? λ*eye(m) : 0)

        if !isempty(fuu)
            QuuF = QuuF + fuuVx
        end

        @end_backward_pass
    end

    return diverge, GaussianDist(N,n,m,K,[],Quu,x,u), Vx, Vxx
end

function back_pass{T}(cx,cu,cxx::AbstractArray{T,2},cxu,cuu,fx::AbstractArray{T,3},fu,λ,regType,lims,u) # quadratic timeinvariant cost, linear time variant dynamics
    @setupQTIC


    for i = N-1:-1:1
        Qu         = cu[:,i] + fu[:,:,i]'Vx[:,i+1]
        Qx         = cx[:,i] + fx[:,:,i]'Vx[:,i+1]
        Qux        = cxu' + fu[:,:,i]'Vxx[:,:,i+1]*fx[:,:,i]
        Quu[:,:,i] = cuu + fu[:,:,i]'Vxx[:,:,i+1]*fu[:,:,i]
        Qxx        = cxx + fx[:,:,i]'Vxx[:,:,i+1]*fx[:,:,i]
        Vxx_reg    = Vxx[:,:,i+1] + (regType == 2 ? λ*eye(n) : 0)
        Qux_reg    = cxu' + fu[:,:,i]'Vxx_reg*fx[:,:,i]
        QuuF       = cuu + fu[:,:,i]'Vxx_reg*fu[:,:,i] + (regType == 1 ? λ*eye(m) : 0)

        @end_backward_pass
    end

    return diverge, GaussianDist(N,n,m,K,[],Quu,x,u), Vx, Vxx
end

function back_pass{T}(cx,cu,cxx::AbstractArray{T,2},cxu,cuu,fx::AbstractMatrix{T},fu,λ,regType,lims,u) # cost quadratic and cost and LTI dynamics

    m,N = size(u)
    n   = size(fx,1)
    cx  = reshape(cx, (n, N))
    cu  = reshape(cu, (m, N))
    cxx = reshape(cxx, (n, n))
    cxu = reshape(cxu, (n, m))
    cuu = reshape(cuu, (m, m))
    k   = zeros(m,N)
    K   = zeros(m,n,N)
    Vx  = zeros(n,N)
    Vxx = zeros(n,n,N)
    dV  = [0., 0.]

    Vx[:,N]    = cx[:,N]
    Vxx[:,:,N] = cxx

    diverge    = 0
    for i = N-1:-1:1
        Qu         = cu[:,i] + fu'Vx[:,i+1]
        Qx         = cx[:,i] + fx'Vx[:,i+1]
        Qux        = cxu' + fu'Vxx[:,:,i+1]*fx

        Quu[:,:,i] = cuu + fu'Vxx[:,:,i+1]*fu
        Qxx        = cxx + fx'Vxx[:,:,i+1]*fx
        Vxx_reg    = Vxx[:,:,i+1] + (regType == 2 ? λ*eye(n) : 0)
        Qux_reg    = cxu' + fu'Vxx_reg*fx

        QuuF       = cuu + fu'Vxx_reg*fu + (regType == 1 ? λ*eye(m) : 0)

        @end_backward_pass
    end

    return diverge, GaussianDist(N,n,m,K,[],Quu,x,u), Vx, Vxx
end


function graphics(x...)
    return 0
end
