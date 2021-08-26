function problem = preprocessAD(problem,varargin) 
% Preprocess automatic differentiation for the problem structure
%
% function problem = preprocessAD(problem)
% function problem = preprocessAD(problem,'egrad')
% function problem = preprocessAD(problem,'ehess')
%
% Check if the automatic differentiation provided in the deep learning tool
% box can be applied to computing the euclidean gradient and the euclidean
% hessian given the manifold and cost function described in the problem
% structure. If AD fails for some reasons, the original problem structure 
% is returned and the approx. of gradient or hessian will then be used 
% as usual. Otherwise, the problem structure with additional fields: 
% egrad, costgrad and ehess is returned. If the user only wants the  
% gradient or the hessian information,the second argument 'egrad' or  
% 'ehess' should be specified. If the egrad or the ehess is alrealdy 
% provided by the user, the complement information is returned by feeding 
% only the problem structure. e.g. if the user has already specified the 
% egrad or grad, he can call problem = preprocessAD(problem,'ehess') or 
% problem = preprocessAD(problem) to obtain the ehess via AD.
%
% In the case that the manifold is the set of fixed-rank matrices with 
% an embedded geometry, it is more efficient to compute the Riemannian 
% gradient directly. However, computing the exact Riemannian Hessian by 
% vecctor product via AD is currently not supported. By calling 
% preprocessAD, the problem struct with additional fields grad and costgrad
% is returned. Besides, optimizing on fixedranktensorembeddedfactory and 
% fixedTTrankfactory via AD is currently not supported.
%
% Note: The current functionality of AD relies on Matlab's deep learning
% tool box, which has the inconvenient effect that we cannot control the
% limitations. Firstly, AD does not support sparse matrices so far. Try 
% converting sparse arrays into full arrays in the cost function. Secondly, 
% math operations involving complex numbers are currently not supported for
% dlarray. To deal with complex problems, see complex_example_AD.m and 
% functions_AD.m for more information.Thirdly, check the list of functions
% with AD supportwhen defining the cost function. See the website: 
% https://ww2.mathworks.cn/help/deeplearning/ug/list-of-functions-with
% -dlarray-support.html and functions_AD.m for brief introduction. To run
% AD on GPU, set gpuflag = true in the problem structure and store 
% related arrays on GPU as usual.See using_gpu_AD for more information.
%
% See also: mat2dl_complex, autograd, egradcompute, ehesscompute
% complex_example_AD, functions_AD, using_gpu_AD

% This file is part of Manopt: www.manopt.org.
% Original author: Xiaowen Jiang, Aug. 31, 2021.
% Contributors: Nicolas Boumal
% Change log: 
%
% To do: Add AD to fixedTTrankfactory, fixedranktensorembeddedfactory
% and the product manifold which contains fixedrankembeddedfactory
% or anchoredrotationsfactory

%% Check if AD can be applied to the manifold and the cost function
    
    assert(isfield(problem,'M') && isfield(problem,'cost'),...,
    'the problem structure must contain the fields M and cost.');
    if nargin==2 
        assert(strcmp(varargin,'egrad')|| strcmp(varargin,'ehess'),...,
        'the second argument should be either ''egrad'' or ''ehess''');       
    end
    % if the gradient and hessian information is provided already, return
    if  (isfield(problem,'egrad') && isfield(problem,'ehess'))..., 
            || (isfield(problem,'egrad') && isfield(problem,'hess'))...,
            || (isfield(problem,'grad') && isfield(problem,'ehess'))...,
            || (isfield(problem,'grad') && isfield(problem,'hess'))...,
            || (isfield(problem,'costgrad') && isfield(problem,'ehess'))...,
            || (isfield(problem,'costgrad') && isfield(problem,'hess'))
        return 
    % AD does not support euclideansparsefactory so far.
    elseif contains(problem.M.name(),'sparsity')
         warning('manopt:sparse',['Automatic differentiation currently does not support '...
                    'sparse matrices']);
        return
    % check availability.
    elseif ~(exist('dlarray', 'file') == 2)
        warning('manopt:dl',['It seems the Deep learning tool box is not installed.'...
         '\nIt is needed for automatic differentiation.\nPlease install the'...
         'latest version of the deep learning tool box and \nupgrade to Matlab'...
         ' 2021a if possible.'])
        return
    else 
        % complexflag is used to detect if the problem defined contains
        % complex numbers.
        complexflag = false;
        % check if AD can be applied to the cost function by passing a
        % point on the manifold to problem.cost.
        x = problem.M.rand();
        try
            dlx = mat2dl(x);
            costtestdlx = problem.cost(dlx);
        catch ME
            % detect complex number by looking up error message
            if (strcmp(ME.identifier,'deep:dlarray:ComplexNotSupported'))
                try
                    dlx = mat2dl_complex(x);
                    costtestx = problem.cost(x);
                    costtestdlx = problem.cost(dlx);
                catch
                    warning('manopt:complex',['Automatic differentiation failed. '...
                    'Problem defining the cost function.'...
                    '\nVariables contain complex numbers.'...
                    'See complex_example_AD.m and functions_AD.m for more\n'...
                    'information about how to deal with complex problems']);
                    return
                end
                % if no error appears, set complexflag to true
                complexflag = true;
            else
                % if the error is not related to complex number, then it
                % must be the problem of defining the cost function
                warning('manopt:costAD',['Automatic differentiation failed. '...
                    'Problem defining the cost function.\n '...
                    '<a href = "https://ww2.mathworks.cn/help/deeplearning'...
                    '/ug/list-of-functions-with-dlarray-support.html">'...
                    'Check the list of functions with AD support.</a>'...
                    'and see functions_AD.m for more information.']);
                return   
            end
        end                   
    end
    if ~(exist('dlaccelerate', 'file') == 2)
        warning('manopt:dlaccelerate', ...
            ['Function dlaccelerate is not available:\nPlease ' ...
            'upgrade to Matlab 2021a and the latest deep\nlearning ' ...
            'toolbox version if possible.\nMeanwhile, auto-diff ' ...
            'may be somewhat slower.\nThe hessian is not available as well.\n' ...
            'To disable this warning: warning(''off'', ''manopt:dlaccelerate'')']);
    end
%% compute the euclidean gradient and the euclidean hessian via AD

    % check if the manifold struct is fixed-rank matrices 
    % with an embedded geometry. for fixedrankembedded factory, 
    % only the Riemannian gradient can be computed via AD so far.
    fixedrankflag = 0;
    if (sum(isfield(x,{'U','S','V'}))==3) &&..., 
        (contains(problem.M.name(),'rank','IgnoreCase',true)) &&...,
        (~startsWith(problem.M.name(),'Product manifold'))
        if ~(exist('varargin', 'var') && strcmp(varargin,'egrad'))
            warning('manopt:fixedrankAD',['computating the exact hessian via '...
            'AD is currently not supported.\n'...
            'To disable this warning: warning(''off'', ''manopt:fixedrankAD'')']);
        end
        % set the fixedrankflag to 1 to prepare for autgrad
        fixedrankflag = 1;
        % if no gradient information is provided, compute grad using AD
        if ~isfield(problem,'egrad') && ~isfield(problem,'grad')...,
            && ~isfield(problem,'costgrad')
            problem.autogradfunc = autograd(problem,fixedrankflag);
            problem.grad = @(x) gradcomputefixedrankembedded(problem,x);
            problem.costgrad = @(x) costgradcomputefixedrankembedded(problem,x);
        else
        % computing the exact hessian via AD is currently not supported
            return
        end
    end
    
    % for other manifolds, provide egrad and ehess via AD. manopt can 
    % get grad and hess automatically through egrad2rgrad and ehess2rhess
    hessianflag = false;
    switch nargin
        case 1
    % if only the hessian information is provided, compute egrad 
    % hessianflag indicates whether or not ehess or hess has provided already 
        if ~isfield(problem,'egrad') && ~isfield(problem,'grad')...,
            && ~isfield(problem,'costgrad') && (isfield(problem,'ehess')...,
            || isfield(problem,'hess'))
        
            problem.autogradfunc = autograd(problem);
            problem.egrad = @(x) egradcompute(problem,x,complexflag);
            problem.costgrad = @(x) costgradcompute(problem,x,complexflag);
            hessianflag = true;
        
    % if only the gradient information is provided, compute ehess     
        elseif ~isfield(problem,'ehess') && ~isfield(problem,'hess')...,
            && (isfield(problem,'costgrad') || isfield(problem,'grad')...,
            || isfield(problem,'egrad')) && (fixedrankflag == 0)
    
            problem.ehess = @(x,xdot,store) ehesscompute(problem,x,xdot,store,complexflag);
        
    % otherwise compute both egrad and ehess via automatic differentiation      
        elseif fixedrankflag == 0
            problem.autogradfunc = autograd(problem);
            problem.egrad = @(x) egradcompute(problem,x,complexflag);
            problem.costgrad = @(x) costgradcompute(problem,x,complexflag);
            problem.ehess = @(x,xdot,store) ehesscompute(problem,x,xdot,store,complexflag);
        end
        
        case 2
    % provide the relevant fields according to varargin
            if strcmp(varargin,'egrad')
                problem.autogradfunc = autograd(problem);
                problem.egrad = @(x) egradcompute(problem,x,complexflag);
                problem.costgrad = @(x) costgradcompute(problem,x,complexflag);
                hessianflag = true;
            elseif strcmp(varargin,'ehess') && (exist('dlaccelerate', 'file') == 2)
                problem.ehess = @(x,xdot,store) ehesscompute(problem,x,xdot,store,complexflag);
            end
            
        otherwise
            error('Too many input arguments');
    end
            
    
%% check whether the cost function can be differentiated or not

    % some functions are not supported to be differentiated with AD in the
    % deep learning tool box. e.g.cat(3,A,B). Check availablility of egrad,
    % if not, remove relevant fields such as egrad and ehess.
    
    if isfield(problem,'autogradfunc') && (fixedrankflag == 0)
        try 
            egrad = problem.egrad(x);
        catch
                warning('manopt:costAD',['Automatic differentiation failed. '...
                    'Problem defining the cost function.\n '...
                    '<a href = "https://ww2.mathworks.cn/help/deeplearning'...
                    '/ug/list-of-functions-with-dlarray-support.html">'...
                    'Check the list of functions with AD support.</a>'...
                    'and see functions_AD.m for more information.']);
            problem = rmfield(problem,'egrad');
            if ~hessianflag
                problem = rmfield(problem,'ehess');
            end
            return
        end
        if any(isnan(egrad(:)))
             warning('manopt:NaNAD',['Automatic differentiation failed. '...
                    'Problem defining the cost function.\n '...
                    'NaN comes up in the computation of egrad via AD.\n'...
                    'Check the example thomson_problem.m for more information.']);           
        end
    % if only the egrad or grad is provided, check ehess
    elseif ~isfield(problem,'autogradfunc') && (fixedrankflag == 0) &&...,
            ~hessianflag && isfield(problem,'ehess')
        % randomly generate a point in the tangent space at x
        xdot = problem.M.randvec(x);
        store = struct();
        try 
            ehess = problem.ehess(x,xdot,store);
        catch
            warning('manopt:costAD',['Automatic differentiation failed. '...
                    'Problem defining the cost function.\n '...
                    '<a href = "https://ww2.mathworks.cn/help/deeplearning'...
                    '/ug/list-of-functions-with-dlarray-support.html">'...
                    'Check the list of functions with AD support.</a>'...
                    'and see functions_AD.m for more information.']);
            problem = rmfield(problem,'ehess');
            return
        end
        if any(isnan(ehess(:)))
             warning('manopt:NaNAD',['Automatic differentiation failed. '...
                    'Problem defining the cost function.\n '...
                    'NaN comes up in the computation of egrad via AD.\n'...
                    'Check the example thomson_problem.m for more information.']);           
        end
    % check the case of fixed rank matrices endowed with an embedded geometry 
    elseif isfield(problem,'autogradfunc') && fixedrankflag == 1
        try 
            grad = problem.grad(x);
        catch
            warning('manopt:costAD',['Automatic differentiation failed. '...
                    'Problem defining the cost function.\n '...
                    '<a href = "https://ww2.mathworks.cn/help/deeplearning'...
                    '/ug/list-of-functions-with-dlarray-support.html">'...
                    'Check the list of functions with AD support.</a>'...
                    'and see functions_AD.m for more information.']);
            problem = rmfield(problem,'grad');
            return
        end
        if any(isnan(grad(:)))
             warning('manopt:NaNAD',['Automatic differentiation failed. '...
                    'Problem defining the cost function.\n '...
                    'NaN comes up in the computation of egrad via AD.\n'...
                    'Check the example thomson_problem.m for more information.']);           
        end
        
    end
    
    
end