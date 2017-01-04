initialize{uType}(integrator,cache::OrdinaryDiffEqCache,::Type{uType}) =
                error("This algorithm does not have an initialization function")

@inline function ode_loopheader!(integrator)
  integrator.iter += 1
  if !isempty(integrator.opts.tstops)
    if integrator.opts.adaptive
      if integrator.tdir > 0
        integrator.dt = min(abs(integrator.dt),abs(top(integrator.opts.tstops)-integrator.t)) # Step to the end
      else
        integrator.dt = -min(abs(integrator.dt),abs(top(integrator.opts.tstops)-integrator.t))
      end
    elseif integrator.dtcache == zero(integrator.t) # Use integrator.opts.tstops
      integrator.dt = integrator.tdir*abs(top(integrator.opts.tstops)-integrator.t)
    else # always try to step with dtcache
      integrator.dt = integrator.tdir*min(abs(integrator.dtcache),abs(top(integrator.opts.tstops)-integrator.t)) # Step to the end
    end
  end
end

@def ode_exit_conditions begin
  if integrator.iter > integrator.opts.maxiters
    warn("Interrupted. Larger maxiters is needed.")
    ode_postamble!(integrator)
    return nothing
  end
  if integrator.dt == zero(integrator.t)
    warn("dt == 0. Aborting")
    ode_postamble!(integrator)
    return nothing
  end
  if any(isnan,integrator.uprev)
    warn("NaNs detected. Aborting")
    ode_postamble!(integrator)
    return nothing
  end
end

@inline function ode_savevalues!(integrator)
  while !isempty(integrator.opts.saveat) && integrator.tdir*top(integrator.opts.saveat) <= integrator.tdir*integrator.t # Perform saveat
    integrator.saveiter += 1
    curt = pop!(integrator.opts.saveat)
    if integrator.opts.saveat!=integrator.t # If <t, interpolate
      ode_addsteps!(integrator)
      Θ = (curt - integrator.tprev)/integrator.dt
      val = ode_interpolant(Θ,integrator)
      copyat_or_push!(integrator.sol.t,integrator.saveiter,curt)
      copyat_or_push!(integrator.sol.u,integrator.saveiter,val)
    else # ==t, just save
      copyat_or_push!(integrator.sol.t,integrator.saveiter,integrator.t)
      copyat_or_push!(integrator.sol.u,integrator.saveiter,integrator.u)
      if integrator.opts.dense
        integrator.saveiter_dense += 1
        copyat_or_push!(integrator.sol.k,integrator.saveiter_dense,integrator.k)
        copyat_or_push!(integrator.notsaveat_idxs,integrator.saveiter_dense,integrator.saveiter)
      end
    end
  end
  if integrator.opts.save_timeseries && integrator.iter%integrator.opts.timeseries_steps==0
    integrator.saveiter += 1
    copyat_or_push!(integrator.sol.u,integrator.saveiter,integrator.u)
    copyat_or_push!(integrator.sol.t,integrator.saveiter,integrator.t)
    if integrator.opts.dense
      integrator.saveiter_dense += 1
      copyat_or_push!(integrator.sol.k,integrator.saveiter_dense,integrator.k)
      copyat_or_push!(integrator.notsaveat_idxs,integrator.saveiter_dense,integrator.saveiter)
    end
  end
  if isspecialdense(integrator.alg)
    resize!(integrator.k,integrator.kshortsize)
  end
end

@inline function ode_postamble!(integrator)
  if integrator.sol.t[end] !=  integrator.t
    integrator.saveiter += 1
    copyat_or_push!(integrator.sol.t,integrator.saveiter,integrator.t)
    copyat_or_push!(integrator.sol.u,integrator.saveiter,integrator.u)
    if integrator.opts.dense
      integrator.saveiter_dense +=1
      copyat_or_push!(integrator.sol.k,integrator.saveiter_dense,integrator.k)
      copyat_or_push!(integrator.notsaveat_idxs,integrator.saveiter_dense,integrator.saveiter)
    end
  end
  !(typeof(integrator.prog)<:Void) && Juno.done(integrator.prog)
end

@inline function ode_loopfooter!(integrator)
  if integrator.opts.adaptive
    q11 = integrator.EEst^integrator.opts.beta1
    q = q11/(integrator.qold^integrator.opts.beta2)
    q = max(integrator.qmaxc,min(integrator.qminc,q/integrator.opts.gamma))
    dtnew = integrator.dt/q
    ttmp = integrator.t + integrator.dt
    if !integrator.opts.isoutofdomain(ttmp,integrator.u) && integrator.EEst <= 1.0 # Accept
      integrator.t = ttmp
      integrator.qold = max(integrator.EEst,integrator.opts.qoldinit)
      if integrator.tdir > 0
        integrator.dtpropose = min(integrator.opts.dtmax,dtnew)
      else
        integrator.dtpropose = max(integrator.opts.dtmax,dtnew)
      end
      if integrator.tdir > 0
        integrator.dtpropose = max(integrator.dtpropose,integrator.opts.dtmin) #abs to fix complex sqrt issue at end
      else
        integrator.dtpropose = min(integrator.dtpropose,integrator.opts.dtmin) #abs to fix complex sqrt issue at end
      end
      if !(typeof(integrator.opts.callback)<:Void)
        integrator.opts.callback(integrator)
      else
        ode_savevalues!(integrator)
      end

      if typeof(integrator.u) <: AbstractArray
        recursivecopy!(integrator.uprev,integrator.u)
      else
        integrator.uprev = integrator.u
      end

      integrator.dt = integrator.dt_mod*integrator.dtpropose

      if isfsal(integrator.alg)
        if integrator.reeval_fsal || (typeof(integrator.alg)<:DP8 && !integrator.opts.calck)
          # Under these condtions, these algorithms are not FSAL anymore
          if typeof(integrator.fsalfirst) <: AbstractArray
            integrator.f(integrator.t,integrator.u,integrator.fsalfirst)
          else
            integrator.fsalfirst = integrator.f(integrator.t,integrator.u)
          end
          integrator.reeval_fsal = false
        else
          if typeof(integrator.fsalfirst) <: AbstractArray
            recursivecopy!(integrator.fsalfirst,integrator.fsallast)
          else
            integrator.fsalfirst = integrator.fsallast
          end
        end
      end

      if integrator.calcprevs
        integrator.tprev = integrator.t
        if !isspecialdense(integrator.alg) && integrator.opts.calck
          if typeof(integrator.k) <: AbstractArray
            recursivecopy!(integrator.kprev,integrator.k)
          else
            integrator.kprev = integrator.k
          end
        end
      end
    else # Reject
      integrator.dt = integrator.dt/min(integrator.qminc,q11/integrator.opts.gamma)
    end
  else #Not adaptive
    integrator.t += integrator.dt

    if !(typeof(integrator.opts.callback)<:Void)
      integrator.opts.callback(integrator)
    else
      ode_savevalues!(integrator)
    end

    if typeof(integrator.u) <: AbstractArray
      recursivecopy!(integrator.uprev,integrator.u)
    else
      integrator.uprev = integrator.u
    end

    integrator.dt *= integrator.dt_mod

    if isfsal(integrator.alg)
      if integrator.reeval_fsal || (typeof(integrator.alg)<:DP8 && !integrator.opts.calck) || typeof(integrator.alg)<:Union{Rosenbrock23,Rosenbrock32}
        # Under these condtions, these algorithms are not FSAL anymore
        if typeof(integrator.fsalfirst) <: AbstractArray
          integrator.f(integrator.t,integrator.u,integrator.fsalfirst)
        else
          integrator.fsalfirst = integrator.f(integrator.t,integrator.u)
        end
        integrator.reeval_fsal = false
      else
        if typeof(integrator.fsalfirst) <: AbstractArray
          recursivecopy!(integrator.fsalfirst,integrator.fsallast)
        else
          integrator.fsalfirst = integrator.fsallast
        end
      end
    end

    if integrator.calcprevs
      integrator.tprev = integrator.t
      if !isspecialdense(integrator.alg) && integrator.opts.calck
        if typeof(integrator.k) <: AbstractArray && !isspecialdense(integrator.alg)
          recursivecopy!(integrator.kprev,integrator.k)
        else
          integrator.kprev = integrator.k
        end
      end
    end
  end
  if !(typeof(integrator.prog)<:Void) && integrator.opts.progress && integrator.iter%integrator.opts.progress_steps==0
    Juno.msg(integrator.prog,integrator.opts.progress_message(integrator.dt,integrator.t,integrator.u))
    Juno.progress(integrator.prog,integrator.t/integrator.sol.prob.tspan[2])
  end
end
