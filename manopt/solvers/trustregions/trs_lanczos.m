function trsoutput = trs_lanczos(problem, trsinput, options, storedb, key)
if nargin == 3 && isempty(problem) && isempty(trsinput)
    trsoutput.printheader = sprintf('%9s   %9s   %s', 'numinner', ...
                            'hessvec', 'stopreason');
    trsoutput.initstats = struct('numinner', 0, 'hessvecevals', 0);
    return;
end

x = trsinput.x;
Delta = trsinput.Delta;
grad = trsinput.fgradx;

M = problem.M;
n = M.dim();

inner   = @(u, v) M.inner(x, u, v);
tangent = @(u) M.tangent(x, u);

% Set local defaults here
localdefaults.kappa = 0.1;
localdefaults.theta = 1.0;
localdefaults.mininner = 1;
localdefaults.maxinner = M.dim();
localdefaults.maxiter_newton = 100;
localdefaults.tol_newton = 1e-16;

% Merge local defaults with user options, if any
if ~exist('options', 'var') || isempty(options)
    options = struct();
end
options = mergeOptions(localdefaults, options);

theta = options.theta;
kappa = options.kappa;

% returned boolean to trustregions.m. true if we are limited by the TR
% boundary (returns boundary solution). Otherwise false.
limitedbyTR = false;

% Pick the zero vector
eta = M.zerovec(x); %s_0
Heta = M.zerovec(x);
r = grad; % g_0
e_Pe = 0; 

r_r = inner(r, r);
norm_r0 = sqrt(r_r);
norm_r = norm_r0;

% Precondition the residual.
z = getPrecon(problem, x, r, storedb, key);

% Compute z'*r.
z_r = inner(z, r);
d_Pd = z_r;

% gamma_0 used in lanczos tridiagonal problem
gamma_0 = sqrt(z_r);

% Initial search direction (we maintain -delta in memory, called mdelta, to
% avoid a change of sign of the tangent vector.)
mdelta = z; % p_0
e_Pd = 0;

% interior is false means we solve tridiagonal trust-region subproblem
% (5.3)
interior = true;

% Lanczos iteratively produces an orthonormal basis of tangent vectors
% which tridiagonalize the Hessian. The corresponding tridiagonal
% matrix is preallocated here as a sparse matrix.
T = spdiags(zeros(n, 3), -1:1, n, n);

% If the Hessian or a linear Hessian approximation is in use, it is
% theoretically guaranteed that the model value decreases strictly
% with each iteration of tCG. Hence, there is no need to monitor the model
% value. But, when a nonlinear Hessian approximation is used (such as the
% built-in finite-difference approximation for example), the model may
% increase. It is then important to terminate the tCG iterations and return
% the previous (the best-so-far) iterate. The variable below will hold the
% model value.
%
% This computation could be further improved based on Section 17.4.1 in
% Conn, Gould, Toint, Trust Region Methods, 2000.
% If we make this change, then also modify trustregions to gather this
% value from tCG rather than recomputing it itself.
model_fun = @(eta, Heta) inner(eta, grad) + .5*inner(eta, Heta);
model_fun_lower = @(eta, gg, H) dot(eta, gg) + .5* dot(eta, H * eta);
model_value = 0;

% Pre-assume termination because j == end.
stopreason_str = 'maximum inner iterations';

% This call is the computationally expensive step.
Hmdelta = getHessian(problem, x, mdelta, storedb, key);

% Compute curvature (often called kappa).
d_Hd = inner(mdelta, Hmdelta); % p_k Hp_k


% Note that if d_Hd == 0, we will exit at the next "if" anyway.
alpha = z_r/d_Hd;

Q = cell(n, 1);

% gep_out = trs_gep(problem, trsinput, options);
% eta_gep = gep_out.eta;
% Heta_gep = gep_out.Heta;
% Begin inner/tCG loop.
for j = 1 : min(options.maxinner, n)

    % obtain T_k from T_{k-1}
    if j == 1
        T(j, j) = 1/alpha; %alpha_j
        Q{j} = M.lincomb(x, 1/sqrt(z_r), z);
        sigma_k = -sign(alpha);
    else
        T(j-1, j) = sqrt(beta)/abs(prevalpha); %sqrt(beta_{j-1})/abs(alpha_{j-1})
        T(j, j-1) = sqrt(beta)/abs(prevalpha); %sqrt(beta_{j-1})/abs(alpha_{j-1})
        T(j, j) = 1/alpha + beta/prevalpha;
%         if sqrt(z_r) > 1e-12
        q = M.lincomb(x, sigma_k/sqrt(z_r), z);
%         else
%             v = M.randvec(x);
%             % Orthogonalize in the style of a modified Gram-Schmidt.
%             for k = 1 : j-1
%                 v = M.lincomb(x, 1, v, -inner(v, Q{k}), Q{k});
%             end
%             v_prec = getPrecon(problem, x, v, storedb, key);
%             v_pnorm = sqrt(inner(v, v_prec));
%             q = M.lincomb(x, sigma_k/v_pnorm, v);
%         end
        sigma_k = - sign(alpha) * sigma_k;
        q = tangent(q);
        Q{j} = q;
    end
    
    if options.debug > 2
        fprintf('DBG:   (r,r)  : %e\n', r_r);
        fprintf('DBG:   (d,Hd) : %e\n', d_Hd);
        fprintf('DBG:   alpha  : %e\n', alpha);
    end

    if interior
        % <neweta,neweta>_P =
        % <eta,eta>_P + 2*alpha*<eta,delta>_P + alpha*alpha*<delta,delta>_P
        e_Pe_new = e_Pe + 2.0*alpha*e_Pd + alpha*alpha*d_Pd;
        
        % Check against negative curvature and trust-region radius violation.
        % If either condition triggers, we switch to lanczos.
        if (alpha <= 0 || e_Pe_new >= Delta^2)
            interior = false;
            limitedbyTR = true;
            tcg_out = trs_tCG(problem, trsinput, options, storedb, key);
            disp(j - tcg_out.stats.numinner);
            disp(tcg_out.printstr);
        else
            % No negative curvature and eta_prop inside TR: accept it.
            e_Pe = e_Pe_new;
            new_eta  = M.lincomb(x, 1, eta, -alpha, mdelta);
        
            % If only a nonlinear Hessian approximation is available, this is
            % only approximately correct, but saves an additional Hessian call.
            % TODO: this computation is redundant with that of r, L241. Clean up.
            new_Heta = M.lincomb(x, 1, Heta, -alpha, Hmdelta);
        
            % Verify that the model cost decreased in going from eta to new_eta. If
            % it did not (which can only occur if the Hessian approximation is
            % nonlinear or because of numerical errors), then we return the
            % previous eta (which necessarily is the best reached so far, according
            % to the model cost). Otherwise, we accept the new eta and go on.
            new_model_value = model_fun(new_eta, new_Heta);
            if new_model_value >= model_value
                stopreason_str = 'model increased';
                break;
            end
            eta = new_eta;
            Heta = new_Heta;
            model_value = new_model_value; %% added Feb. 17, 2015
        end
    end
    
    % solve tridiagonal trust-region subproblem to obtain h
    if ~interior
        [h, limitedbyTR, trouble, accurate] = TRSgep(T(1:j, 1:j), gamma_0*eye(j, 1), Delta);
%         [h, newton_iter] = minimize_quadratic_gltr(T(1:j, 1:j), ...
%                                gamma_0*eye(j, 1), Delta, options);
%         if trouble || ~accurate
%             disp(j);
%         end
    end
    % Update the residual.
    r = M.lincomb(x, 1, r, -alpha, Hmdelta);
    
    % Compute new norm of r.
    r_r = inner(r, r);
    norm_r = sqrt(r_r);

    % Precondition the residual.
    z = getPrecon(problem, x, r, storedb, key);
    
    % Save the old z'*r.
    zold_rold = z_r;

    % Compute new z'*r.
    z_r = inner(z, r);

    beta = z_r/zold_rold;

    if interior
        % Check kappa/theta stopping criterion.
        % Note that it is somewhat arbitrary whether to check this stopping
        % criterion on the r's (the gradients) or on the z's (the
        % preconditioned gradients). [CGT2000], page 206, mentions both as
        % acceptable criteria.
        conv_test = norm_r;
    else
        % gamma_{k+1} |< e_{k+1}, h_k>|
        conv_test = sqrt(beta)/abs(alpha) * abs(dot(double(1:j == j), h));
%         disp(j);
%         disp(model_fun_lower(h, gamma_0*eye(j, 1), T(1:j, 1:j)) - model_fun(eta_gep, Heta_gep));
%         eta_t = lincomb(M, x, Q(1:numel(h)), h);
%         eta_t = tangent(eta_t);
%         Heta_t= getHessian(problem, x, eta_t, storedb, key);

%         g_kp1 = M.lincomb(x, 1, grad, 1, Heta_t);
%         g_kp1_prec = getPrecon(problem, x, g_kp1, storedb, key);
%         disp(sqrt(inner(g_kp1, g_kp1_prec)));
%         disp(conv_test);
    end
    if j >= options.mininner && conv_test <= norm_r0*min(norm_r0^theta, kappa)
        % Residual is small enough to quit
        if kappa < norm_r0^theta
            stopreason_str = 'reached target residual-kappa (linear)';
        else
            stopreason_str = 'reached target residual-theta (superlinear)';
        end
        if interior
            stopreason_str = append(stopreason_str,' tCG');
%             tcg_out = trs_tCG(problem, trsinput, options, storedb, key);
%             disp(tcg_out.printstr);
%             disp(j - tcg_out.stats.numinner);
        else
            stopreason_str = append(stopreason_str,' lanczos');
        end
        break;
    end

    % Compute new search direction.
    mdelta = M.lincomb(x, 1, z, beta, mdelta);
    
    % Since mdelta is passed to getHessian, which is the part of the code
    % we have least control over from here, we want to make sure mdelta is
    % a tangent vector up to numerical errors that should remain small.
    % For this reason, we re-project mdelta to the tangent space.
    % In limited tests, it was observed that it is a good idea to project
    % at every iteration rather than only every k iterations, the reason
    % being that loss of tangency can lead to more inner iterations being
    % run, which leads to an overall higher computational cost.
    mdelta = tangent(mdelta);
    
    % Update new P-norms and P-dots [CGT2000, eq. 7.5.6 & 7.5.7].
    e_Pd = beta*(e_Pd + alpha*d_Pd);
    d_Pd = z_r + beta*beta*d_Pd;
    
    % This call is the computationally expensive step.
    Hmdelta = getHessian(problem, x, mdelta, storedb, key);

    % Compute curvature (often called kappa).
    d_Hd = inner(mdelta, Hmdelta); % p_k Hp_k

    % Note that if d_Hd == 0, we will exit at the next "if" anyway.
    prevalpha = alpha;
    alpha = z_r/d_Hd;

    % Pre-assume termination because j == end.
    stopreason_str = 'maximum inner iterations';
end  % of loop

% regenerate lanczos vectors to get Q_k matrix and recover the solution y = Q_k h_k
if ~interior
%     t_j = grad;
%     w_jm1 = M.zerovec(x);
%     Q_test = cell(numel(h), 1);
%     for j = 1:numel(h)
%         y_j = getPrecon(problem, x, t_j, storedb, key);
%         gamma_j = sqrt(inner(t_j, y_j));
%         w_j = M.lincomb(x, 1/gamma_j, t_j);
%         q_j = M.lincomb(x, 1/gamma_j, y_j);
%         Q_test{j} = q_j;
% 
%         % This call is the computationally expensive step.
%         Hq_j = getHessian(problem, x, q_j, storedb, key);
%         delta_j = inner(q_j, Hq_j);
%         t_j = M.lincomb(x, 1, Hq_j, -delta_j, w_j);
%         t_j = M.lincomb(x, 1, t_j, -gamma_j, w_jm1);
%         w_jm1 = w_j;
%     end
%     eta_regen = lincomb(M, x, Q_test(1:numel(h)), h);
%     eta_regen = tangent(eta_regen);
%     Heta_regen = getHessian(problem, x, eta_regen, storedb, key);

    eta = lincomb(M, x, Q(1:numel(h)), h);
    eta = tangent(eta);
    Heta = getHessian(problem, x, eta, storedb, key);
%     trs_tCG_out = trs_tCG(problem, trsinput, options, storedb, key);
%     eta_tCG = trs_tCG_out.eta;
%     Heta_tCG = trs_tCG_out.Heta;
%     if  abs(model_fun(eta, Heta) - model_fun(eta_regen, Heta_regen)) > 1e-10
%         disp('model_fun_soln, regen');
%         disp([model_fun(eta, Heta), model_fun(eta_regen, Heta_regen)]);
%         disp('model_fun_regen');
%         disp(model_fun(eta_regen, Heta_regen));
%     end
%     if model_fun(eta, Heta) > model_fun(eta_tCG, Heta_tCG)
%         disp('GREATER');
%         disp('model_fun_soln');
%         disp(model_fun(eta, Heta));
%         disp('model_fun_tCG');
%         disp(model_fun(eta_tCG, Heta_tCG));
%     end
end
if j <= min(options.maxinner, n)
%     gep_out = trs_gep(problem, trsinput, options);
%     eta_gep = gep_out.eta;
%     Heta_gep = gep_out.Heta;
%     disp('model_fun, gep');
%     if inner(eta, eta) >= Delta^2
%         disp('eta norm');
%         disp(inner(eta, eta) - Delta^2);
% %         disp(inner(eta, getPrecon(problem, x, eta, storedb, key)) - Delta^2);
%     end
%     disp([model_fun(eta, Heta), model_fun(eta_gep, Heta_gep)]);
%     disp(abs(model_fun(eta, Heta)- model_fun(eta_gep, Heta_gep)));
end
printstr = sprintf('%9d   %9d   %s', j, j, stopreason_str);
stats = struct('numinner', j, 'hessvecevals', j);

trsoutput.eta = eta;
trsoutput.Heta = Heta;
trsoutput.limitedbyTR = limitedbyTR;
trsoutput.printstr = printstr;
trsoutput.stats = stats;
end
