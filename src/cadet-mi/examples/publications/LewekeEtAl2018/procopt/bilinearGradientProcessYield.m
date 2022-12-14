function [optCut, optGrad, optYield, optPurity, overlaps, optResult] = bilinearGradientProcessYield(initCutPoints, initGradient, colLength, elutionConstraint, algorithm)
%BILINEARGRADIENTPROCESSYIELD Calculates optimal cut times and salt gradient with respect to maximum yield under purity constraints
%
%   Introducing the mass m_i of component i between the cut points t_1 and 
%   t_2 as
%             / t_2
%      m_i = |      c_i(t) dt,
%            / t_1
%  
%   yield y_i is defined by
%      y_i = m_i / ( c_inj * t_inj )
%   and purity is given by
%      p_i = m_i / (m_1 + m_2 + m_3).
%  
%   The optimization problem then reads
%     max   y_2
%     s.t.  c_1( t_end ) <= 1e-6                Complete elution of comp 1
%           c_2( t_end ) <= 1e-6                Complete elution of comp 2
%           c_3( t_end ) <= 1e-6                Complete elution of comp 3
%           c_salt(t_endGrad1) <= 1000          Salt gradient monotonicity
%           p_2 >= 0.95                         Purity constraint
%           t_1 <= t_2                          Cut times ordering
%           params <= ub                        Upper box constraint
%           params >= lb                        Lower box constraint
%  
%   The parameters are ordered as [gradient params, cut times].
%   
%   The chromatogram is simulated and converted to a cubic spline. In order
%   to evaluate m_i, the spline, which is a piecewise polynomial, is
%   integrated analytically by calculating its anti-derivative.
%  
%   By interchanging differentiation with integration, the derivative of the
%   mass m_i with respect to a gradient shape parameter p_j is given by
%      dm_i       / t_2  dc_i
%      ---- =    |       ----(t) dt,
%      dp_j      / t_1   dp_j
%   where the sensitivity of c_i with respect to p_j is converted to a cubic
%   spline.
%   For cut time parameters t_1, t_2 by the  we have
%      dm_i                    dm_i
%      ---- = c_i(t_2)   and   ---- = -c_i(t_1)
%      dt_2                    dt_1
%  
%   The constraints that enforce complete elution used above can be changed to
%   another set of constraints:
%            \int_0^{t_end} c_1(t) dt >= 0.995 * injMass_1
%            \int_0^{t_end} c_2(t) dt >= 0.995 * injMass_2
%            \int_0^{t_end} c_3(t) dt >= 0.995 * injMass_3
%   These constraints require that the eluted mass is at least 99.5 % of the
%   injected mass of each component. The first set of constraints described
%   in the problem formulation above is selected by choosing ELUTIONCONSTRAINT = 1.
%   The eluted mass constraints described here are selected by setting 
%   ELUTIONCONSTRAINT = 2. These integrals are computed using Simpson's rule
%   as the gradient with respect to c_i(t_j) is required (which is not easily
%   retrieved from the spline approach used for the other integrals).
%
%   A bilinear gradient is assumed. The design parameters are (in order):
%     Start concentration of gradient 1 in mM, slope of gradient 1 in mM / s,
%     and length of gradient 1 in s.
%   The total process time is fixed and the gradients are assumed to be
%   continuous, i.e., there is no step between gradient 1 and 2. Furthermore,
%   the second gradient has to reach the final (pre-defined) high salt
%   concentration.
%  
%   The employed model describes ion-exchange chromatography of lysozyme,
%   cytochrome, and ribonuclease on the strong cation-exchanger 
%   SP Sepharose FF. Model parameters are taken from benchmark 2 of the 
%   following publication:
%   A. P??ttmann, S. Schnittert, U. Naumann & E. von Lieres (2013).
%   Fast and accurate parameter sensitivities for the general rate model of
%   column liquid chromatography.
%   Computers & Chemical Engineering, 56, 46???57.
%   doi:10.1016/j.compchemeng.2013.04.021
%
%   BILINEARGRADIENTPROCESSYIELD(INITCUTPOINTS, INITGRADIENT) uses the initial
%   cut points (vector with start and stop time) INITCUTPOINTS and the initial
%   gradient design given by height of the first gradient, slope of first
%   gradient, and length of first gradient (vector with 3 components) in INITGRADIENT
%   to perform the optimization.
%
%   BILINEARGRADIENTPROCESSYIELD(..., COLLENGTH) additionally specifies the
%   length of the column which defaults to 0.014m.
%
%   BILINEARGRADIENTPROCESSYIELD(..., COLLENGTH, ELUTIONCONSTRAINT) additionally
%   sets the constraint type that enforces complete elution. If ELUTIONCONSTRAINT = 1, 
%   the concentration at the end of the profile is constrained to 1e-6 mM. If 
%   ELUTIONCONSTRAINT = 2, the eluted mass has to be at least 99.5 % of the injected mass.
%
%   BILINEARGRADIENTPROCESSYIELD(..., COLLENGTH, ELUTIONCONSTRAINT, ALGORITHM) 
%   additionally sets the algorithm used by FMINCON (e.g., 'interior-point', 'sqp').
%
%   [OPTCUT, OPTGRAD, OPTYIELD, OPTPURITY, OVERLAPS, OPTRESULT] = BILINEARGRADIENTPROCESSYIELD(...)
%   returns a vector with the optimal cut points in OPTCUT, the optimal gradient
%   design in OPTGRAD, the achieved yield in OPTYIELD, the achieved purity in
%   OPTPURITY, and the overlaps of the peaks in OVERLAPS (lysozyme-cytochrome,
%   lysozyme-ribonuclease, and cytochrome-ribonuclease). Additionally returns
%   a struct OPTRESULT with output of the optimizer FMINCON.
%
% See also LOADWASHELUTIONSMASINGLE, PARAMETERIZEDSIMULATIONMIXED, BILINEARGRADIENTPROCESSOVERLAPSUM
%   BILINEARGRADIENTPROCESSOVERLAPMAX, RUNWORKFLOWALLINONE, SIMPS, FMINCON

% Copyright: ?? 2015 Samuel Leweke, Eric von Lieres
%            See the license note at the end of the file.

	% Set some defaults
	if (nargin <= 0) || isempty(initCutPoints)
		initCutPoints = [2200, 3100];
	end

	if (nargin <= 1) || isempty(initGradient)
		initGradient = [56, 0.04, 4900];
	end
	
	if (nargin <= 2) || isempty(colLength)
		colLength = 0.014;
	end

	if (nargin <= 3) || isempty(elutionConstraint)
		elutionConstraint = 1;
	end

	if (nargin <= 4) || isempty(algorithm)
		algorithm = 'interior-point';
	end
	
	% Target component is 2 (index would be 3 when including salt)
	idxTarget = 2;
	
	% Minimum purity constraint (95 %)
	minPurity = 0.95;

	% Parameters for the CADET solver (all parameters that vary and / or need derivatives; 
	% hence, more parameters than optimization parameters are specified here).
	params = cell(5, 1);

	% Each parameter is identified by 
	%   - its unit operation id (0-based index or -1 if independent),
	%   - name (according to CADET file format specification),
	%   - component index (0-based index or -1 if independent),
	%   - reaction index (0-based index or -1 if independent),
	%   - bound phase index (0-based index or -1 if independent), and
	%   - time integrator section index (0-based index or -1 if independent).

	% Parameter 1: CONST_COEFF of component 1 (salt, component 0 if read as 0-based) in 
	%              inlet unit operation (id 1) and time section 3 (2 if read as 0-based)
	params{1} = makeSensitivity([1], {'CONST_COEFF'}, [0], [-1], [-1], [-1], [2]);

	% Parameter 1: LIN_COEFF of component 1 (salt, component 0 if read as 0-based) in 
	%              inlet unit operation (id 1) and time section 3 (2 if read as 0-based)
	params{2} = makeSensitivity([1], {'LIN_COEFF'}, [0], [-1], [-1], [-1], [2]);

	% Parameter 1: CONST_COEFF of component 1 (salt, component 0 if read as 0-based) in 
	%              inlet unit operation (id 1) and time section 4 (3 if read as 0-based)
	params{3} = makeSensitivity([1], {'CONST_COEFF'}, [0], [-1], [-1], [-1], [3]);

	% Parameter 1: LIN_COEFF of component 1 (salt, component 0 if read as 0-based) in 
	%              inlet unit operation (id 1) and time section 4 (3 if read as 0-based)
	params{4} = makeSensitivity([1], {'LIN_COEFF'}, [0], [-1], [-1], [-1], [3]);

	% Parameter 5: SECTION_TIMES item 4 (beginning of second gradient, 3 if read as 0-based)
	params{5} = makeSensitivity([-1], {'SECTION_TIMES'}, [-1], [-1], [-1], [-1], [3]);

	% Note that CADET is currently not able to compute the derivative with
	% respect to SECTION_TIMES (i.e., length of the gradient). This derivative
	% will be computed via finite differences. However, due to continuity of
	% the gradients, the derivatives with respect to starting concentration
	% and slope of gradient 2 are required.
	
	% Specifiy linear parameter transform (takes all parameters to rougly
	% the same order of magnitude)
	transform = diag([0.1, 100, 0.01, 0.01, 0.01]);
	invTransform = diag([10, 0.01, 100, 100, 100]);
	
	% Create the model
	sim = createSimulator(colLength);

	% Set parameters
	sim.setParameters(params, [true, true, true, true, false]);

	% Generate rule for numerical integration such that
	% \int f(t) dt = numIntRule' * f(timePoints)
	numIntRule = simps(sim.solutionTimes);

	massLowerLimit = 9.95; % Eluted mass of each component has to be >= massLowerLimit;
	                       % 10 mM are injected, 9.95 mM = 99.5 %

	elutionLimit = 1e-6;   % Threshold for complete elution in mM

	bp = getBasicParams();
	
	% Specify lower and upper bounds on parameters
	% Layout: start, slope1, len, collect start, collect stop
	lb = [bp.initialSalt, 0.001, 120, 0, 0];
	ub = [500, 10, bp.endTime - bp.startTime - 120, bp.endTime, bp.endTime];
	
	% Transform to optimizer space
	% Since we use row vectors, the transformation is
	%   y = A*x   <=>   y^T = x^T * A^T
	lb = lb * transform';
	ub = ub * transform';
	initSol = [initGradient, initCutPoints] * transform';
	
	% Calculate total injected mass of each component
	injMass = sim.sectionTimes(2) .* sim.model.constant(1, 2:end);
	
	% Storage for nested functions
	result = [];
	hdPlot = [];
	bestSol = [];
	bestVal = inf;

	% Optimize
	lastSuccessfulParams = [];
	options = optimoptions('fmincon', 'MaxIter', 300, 'Algorithm', algorithm, 'Diagnostics', 'off', ...
		'GradObj', 'on', 'GradConstr', 'on', 'Display', 'iter', 'OutputFcn', @progressMonitor);
	try
		[optSol, fval, exitflag, output] = fmincon(@yield, initSol, [0, 0, 0, 1, -1], [0], [], [], lb, ub, @constraints, options);
		optSol = bestSol;
		fval = bestVal;
 	catch
 		% Something went wrong
 		if ~isempty(bestSol)
 			optSol = bestSol;
 			fval = bestVal;
 		else
	 		if ~isempty(lastSuccessfulParams)
	 			optSol = lastSuccessfulParams;
	 		else
	 			optSol = initSol;
	 		end
	 		fval = -1;
	 	end
 		exitflag = -1;
 		output = [];
 	end

	% Apply inverse transform to solution in optimizer space
	optGrad = optSol * invTransform';
	optCut = optGrad(4:5);
	optGrad = optGrad(1:3);

	% Evaluate final solution
	disableSensitivities(sim);
	modifyModelParams(sim, optGrad(1:3));

	try
		result = sim.run(true);

		% Compute overlaps
		% Components are (in order): Salt, lysozyme, cytochrome, ribonuclease
		outlet = result.solution.outlet{1};
		overlaps = zeros(3, 1);
		overlaps(1) = numIntRule.' * (min(abs(outlet(:, 2)), abs(outlet(:, 3))));
		overlaps(2) = numIntRule.' * (min(abs(outlet(:, 2)), abs(outlet(:, 4))));
		overlaps(3) = numIntRule.' * (min(abs(outlet(:, 3)), abs(outlet(:, 4))));
		
		% Calculate purity and yield
		[tempSpl, optMasses] = splineAndMasses(result, optCut);
		optYield = optMasses(idxTarget) / injMass(idxTarget);
		optPurity = optMasses(idxTarget) / sum(optMasses);
	catch
		overlaps = nan(3, 1);
		optYield = nan;
		optPurity = nan;
	end
		
	% Collect optimizer output
	optResult.exitflag = exitflag;
	optResult.fval = fval;
	optResult.output = output;
	
	function [f, grad] = yield(x)

		% Inverse transform from optimizer to simulator space
		x = x * invTransform';

		pGrad = x(1:3);
		pCut = x(4:5);
		
		% Perform simulation if parameters have changed
		result = performSimulation(sim, result, x, nargout > 1, pGrad);
		
		% Calculate yield and purity
		[chromSpl, masses] = splineAndMasses(result, pCut);
		f = -masses(idxTarget) / injMass(idxTarget);
		
		grad = [];
		if nargout > 1
			% Calculate gradient
			grad = zeros(size(x));
			% ... with respect to gradient shape
			for i = 1:length(pGrad)
				% Compute integral of target component sensitivities
				sensSpl = pchip(result.solution.time, result.jac(:, idxTarget, i));
				grad(i) = -diff(ppval(ppint(sensSpl), pCut)) / injMass(idxTarget);
			end
			% ... with respect to cut points
			grad(4) = ppval(chromSpl{idxTarget}, pCut(1)) / injMass(idxTarget);
			grad(5) = -ppval(chromSpl{idxTarget}, pCut(2)) / injMass(idxTarget);
	
			% Apply chain rule to take care of the parameter transform T
			%    grad( F(T(x)) ) = [grad F]^T * Jac_T
			grad = grad * invTransform;
		end
	end

	function [c,ceq,gradc,gradceq] = constraints(x)
		% Calculates the constraints
		
		% Inverse transform from optimizer to simulator space
		x = x * invTransform';

		pGrad = x(1:3);
		pCut = x(4:5);
		
		% Perform simulation if parameters have changed
		result = performSimulation(sim, result, x, nargout > 2, pGrad);
		
		bp = getBasicParams();

		% No equality constraints
		ceq = [];

		% Constraint for complete elution
		if elutionConstraint == 1
			% c_i(t_end) <= elutionLimit
			c = [result.solution.outlet{1}(end, 2:end)] - elutionLimit;
		elseif elutionConstraint == 2
			% \int c_i(t) dt >= massLowerLimit  <=>  -\int c_i(t) dt + massLowerLimit <= 0
			c = [-numIntRule.' * result.solution.outlet{1}(:, 2:end)] + massLowerLimit;
		end

		% Constraint on monotonicity of salt gradient:
		%    start + slope1 * length <= maxSalt
		c = [c, x(1) + x(2) * x(3) - bp.maxSalt];

		% Purity constraint
		[chromSpl, masses] = splineAndMasses(result, pCut);
		purity = masses(idxTarget) / sum(masses);
		c = [c, minPurity - purity];
		
		% Compute derivative if requested
		gradc = [];
		gradceq = [];
		if nargout > 2
			% The transposed Jacobian is requested, i.e., the gradients are 
			% standing in the columns.

			gradceq = [];
			
			% Gradient of complete elution constraint
			if elutionConstraint == 1
%				gradc = [squeeze(result.jac(end, 2:end, :)).'; zeros(2, size(result.jac, 3))];
				gradc = [squeeze(result.jac(end, 2:end, :)); zeros(2, size(result.jac, 3))];
			elseif elutionConstraint == 2
				gradc = [-cell2mat(arrayfun(@(idx) squeeze(result.jac(:, idx, :)).' * numIntRule, 2:size(result.jac, 2), 'UniformOutput', false)); zeros(2, size(result.jac, 3))];
			end

			% Gradient of monotonicity constraint
			gradSalt = [1; x(3); x(2); 0; 0];
			
			% Gradient of purity constraint is obtained by applying
			% quotient and chain rule:
			%                                                       ___
			% dpurity     dm_target / dp          m_target         \      dm_i  
			% ------- =  ---------------- -  ------------------- *  |    ------
			%   dp        m_1 + m_2 + m_3    (m_1 + m_2 + m_3)^2   /___    dp
			%                                                        i
			gradPurity = zeros(length(x), 1);
			for i = 1:length(pGrad)
				sensMass = zeros(size(masses));
				sensSpl = cell(size(sensMass));
				for k = 1:length(sensMass)
					% Compute "mass" of derivative of k-th component with
					% respect to i-th parameter
					sensSpl{k} = pchip(result.solution.time, result.jac(:, k+1, i));
					sensMass(k) = diff(ppval(ppint(sensSpl{k}), pCut));
				end
				
				gradPurity(i) = -(sensMass(idxTarget) - masses(idxTarget)  * sum(sensMass) / sum(masses)) / sum(masses);
			end
			gradPurity(4) = (ppval(chromSpl{idxTarget}, pCut(1)) - masses(idxTarget) * (ppval(chromSpl{1}, pCut(1)) + ppval(chromSpl{2}, pCut(1)) + ppval(chromSpl{3}, pCut(1))) / sum(masses)) / sum(masses);
			gradPurity(5) = -(ppval(chromSpl{idxTarget}, pCut(2)) - masses(idxTarget) * (ppval(chromSpl{1}, pCut(2)) + ppval(chromSpl{2}, pCut(2)) + ppval(chromSpl{3}, pCut(2))) / sum(masses)) / sum(masses);
			
			% Assemble all gradients into Jacobian
			gradc = [gradc, gradSalt, gradPurity];
			
			% Apply chain rule to take care of the parameter transform T
			%    grad( F(T(x)) ) = grad F * Jac_T
			% Note that the transposed gradient is returned. Thus, we get
			%    [grad( F(T(X)) )^T = Jac_T^T * (grad F)^T
			gradc = invTransform' * gradc;
		end
	end

	function jac = jacobianModel(sim, result, paramVals)
	%JACOBIANMODEL Computes the Jacobian for the current parameter values
	% Except for the gradient length, the Jacobian can be computed using 
	% CADET's forward sensitivity approach. The gradient with respect to length
	% is computed using finite differences (FD).

		% Relative step size for finite differences wrt. gradient length
		fdFactor = 1e-6;
		
		% Recover parameters
		start = paramVals(1);
		slope1 = paramVals(2);
		len = paramVals(3);

		% Get process parameters
		bp = getBasicParams();
		
		% Turn off sensitivities for FD computation to increase speed
		sim.clearSensitivities(false);

		% Simulate with slightly increased length
		newLen = len * (1 + fdFactor);
		rightRes = sim.runWithParameters(newLen);

		% Simulate with slightly decreased length
		newLen = len * (1 - fdFactor);
		leftRes = sim.runWithParameters(newLen);
		
		% Calculate central finite difference
		jacFD = (rightRes.solution.outlet{1} - leftRes.solution.outlet{1}) ./ (2 * len * fdFactor);
				
		% Calculate full Jacobian (Layout: Start, Slope1, Length)
		
		% Because of the continuity assumption ( end(grad1) = start(grad2) )
		% and the implicit calculation of the second's gradient slope we need
		% to use the chain rule on
		%    F(start, slope1, length) 
		%        = G(start, slope1, start + length*slope1, 
		%             slope2(start, slope1, length), length),
		% where G( start, slope1, intercept of gradient2, slope2, length ) and
		%    slope2(start, slope1, length) = (maxSalt - start - slope1 * length) / (endTime - length - startTime).
		% The layout of the Jacobian as obtained by CADET is 
		%   Start, Slope1, intercept of section 4, Slope2,
		% thus, we need to append the derivative with respect to length (jacFD).
		
		% The gradient of the slope2(start, slope1, length) function is
		%   grad slope2(start, slope1, length) 
		%       = -1 / (endTime - length - startTime) * [1; length; slope1 - (maxSalt - start - slope1*length) / (endTime - length - startTime)].
		%
		% Taking the Jacobian of the inner mapping
		%    h(start, slope1, length)
		%       = [start; slope1; start + length*slope1;
		%          slope2(start, slope1, length); length]
		% gives:
		gradSlope2 = -[1, len, slope1 - (bp.maxSalt - start - slope1*len) / (bp.endTime - len - bp.startTime)] ./ (bp.endTime - len - bp.startTime);
		jacTrans = [1 0 0; 0 1 0; 1 len slope1; gradSlope2; 0 0 1];
		
		localJac = result.sensitivity.jacobian{1};
		jac = zeros(size(jacFD, 1), size(jacFD, 2), size(jacTrans, 2));
		for i = 1:size(jacFD, 2)
			% Apply chain rule for each component
			jac(:, i, :) = [squeeze(localJac(:, i, :)), jacFD(:, i)] * jacTrans;
		end
	end

	function disableSensitivities(sim)
		%DISABLESENSITIVITIES Disables sensitivity computation

		if sim.nSensitiveParameters == 0
			% Sensitivities are already gone, make sure we still have the variable parameters
			if sim.nVariableParameters < 5
				sim.clearParameters();
				sim.setParameters(params, false(size(params)));
			end
		else
			sim.clearSensitivities(true);
		end
	end

	function enableSensitivities(sim)
		%ENABLESENSITIVITIES Enables sensitivity computation

		if sim.nSensitiveParameters >= 4
			return;
		end

		sim.clearParameters();
		sim.setParameters(params, [true, true, true, true, false]);
	end

	function res = performSimulation(sim, res, x, calcJacobian, pGrad)
		%PERFORMSIMULATION Performs a simulation if necessary
		
		% Check if a simulation has been performed already or if parameter values have changed
		if (~isfield(res, 'x')) || (~all(res.x == x)) || (calcJacobian && (~isfield(res, 'jac') || isempty(res.jac)))

			% Decide whether to enable or disable parameter sensitivities
			if calcJacobian
				enableSensitivities(sim);
			else
				disableSensitivities(sim);
				res.jac = [];
			end
			
			modifyModelParams(sim, pGrad);

			% Run simulation
			res = sim.run(true);
			res.x = x;
			
			if calcJacobian
				% Compute the Jacobian
				res.jac = jacobianModel(sim, res, pGrad);
				% Format of the Jacobian jac is 
				%    nTimePoints x nComponents x nParameters,
				% thus, jac(:, j, i) is the derivative of component j with 
				% respect to parameter i.
			end

			lastSuccessfulParams = x;
		end

		if calcJacobian && isempty(res.jac)
			% Compute the Jacobian
			enableSensitivities(sim);
			res = sim.run(true);
			res.x = x;
			res.jac = jacobianModel(sim, res, pGrad);
		end
	end

	function [chromSpl, masses] = splineAndMasses(res, pCut)
		%SPLINEANDMASSES Calculate splines and masses of the result of a simulation

		masses = zeros(size(res.solution.outlet{1}, 2)-1, 1);
		chromSpl = cell(size(masses));
		for i = 1:length(masses)
			chromSpl{i} = pchip(res.solution.time, res.solution.outlet{1}(:, i+1));
			masses(i) = diff(ppval(ppint(chromSpl{i}), pCut));
		end
	end

	function stop = progressMonitor(x, optimValues, state)
		%PROGRESSMONITOR Callback function for progress report invoked by fmincon

		stop = false;
		if ~strcmp(state, 'iter')
			return;
		end
		
		% Save best point
		if (optimValues.constrviolation == 0) && (optimValues.fval <= bestVal)
			bestSol = x;
			bestVal = optimValues.fval;
		end

		% Plot

		% Inverse transform from optimizer to simulator space
		x = x * invTransform';
		pGrad = x(1:3);
		pCut = x(4:5);

		outlet = result.solution.outlet{1};

		% Calculate overlaps
		overlaps = zeros(3,1);
		overlaps(1) = sum(min(abs(outlet(:, 2)), abs(outlet(:, 3))));
		overlaps(2) = sum(min(abs(outlet(:, 2)), abs(outlet(:, 4))));
		overlaps(3) = sum(min(abs(outlet(:, 3)), abs(outlet(:, 4))));

		% Calculate yield and purity
		masses = zeros(size(outlet, 2)-1, 1);
		chromSpl = cell(size(masses));
		for i = 1:length(masses)
			chromSpl{i} = pchip(result.solution.time, outlet(:, i+1));
			masses(i) = diff(ppval(ppint(chromSpl{i}), pCut));
		end
		yield = masses(idxTarget) / injMass(idxTarget);
		purity = masses(idxTarget) / sum(masses);

		% Plot
		bp = getBasicParams();
		start2 = pGrad(1) + pGrad(2) * pGrad(3);
		slope2 = (bp.maxSalt - start2) / (bp.endTime - pGrad(3) - bp.startTime);
		ppInlet = mkpp([0, 10, bp.startTime, bp.startTime + pGrad(3), bp.endTime], ...
			[0 bp.initialSalt; 0 bp.initialSalt; pGrad(2) pGrad(1); slope2, start2]);

		if isempty(hdPlot)			
			hdPlot.figureA = figure('Name', 'Optimization');

			hdPlot.ax = subplot(1, 2, 1);
			hdPlot.outlet = plot(result.solution.time, outlet(:, 2:end));
			grid on;

			% Plot lines for start and end point
			ylim = get(gca,'ylim');
			hold on;
			hdPlot.cutS = line([pCut(1), pCut(1)], [0, ylim(2)], 'LineStyle','-', 'Color','k');
			hdPlot.cutE = line([pCut(2), pCut(2)], [0, ylim(2)], 'LineStyle','-', 'Color','k');
			hold off;

			set(gca, 'ylim', [0, ylim(2)]);
			hdTemp = legend('Lysozyme', 'Cytochrome', 'RNase');
			set(hdTemp, 'Location','NorthWest');
			hdPlot.titleLeft = title(sprintf('1&2: %g  1&3: %g  2&3: %g  Y: %g  P: %g', [overlaps; yield; purity]));

			subplot(1, 2, 2);
			hdPlot.inlet = plot(result.solution.time, ppval(ppInlet, result.solution.time));
			hdTemp = legend('Salt');
			set(hdTemp, 'Location','NorthWest');
			grid on;
			hdPlot.titleRight = title(sprintf('Start %g Slope1 %g Length %g SC %g EC %g', x));

			hdPlot.figureProcMon = figure('Name', 'Process Monitor');
			subplot(1, 2, 1);
			hdPlot.opt = semilogy(optimValues.iteration, [-optimValues.fval, optimValues.constrviolation, optimValues.firstorderopt, optimValues.stepsize], 'x-');
			hdTemp = legend('Function value', 'Constraint violation', 'Optimality', 'Step size');
			set(hdTemp, 'Location','SouthWest');
			hdPlot.optTitle = title(sprintf('Iteration %d', optimValues.iteration));
			grid on;

			subplot(1, 2, 2);
			hdPlot.param = plot(optimValues.iteration, x, 'x-');
			hdPlot.paramTitle = title('Parameters');
			grid on;
		else
			for i = 1:numel(hdPlot.outlet)
				set(hdPlot.outlet(i), 'YData', outlet(:, i+1));
			end
			ylim = get(hdPlot.ax, 'ylim');

			set(hdPlot.cutS, 'XData', [pCut(1), pCut(1)], 'YData', [0, ylim(2)]);
			set(hdPlot.cutE, 'XData', [pCut(2), pCut(2)], 'YData', [0, ylim(2)]);
			set(hdPlot.titleLeft, 'String', sprintf('1&2: %g  1&3: %g  2&3: %g  Y: %g  P: %g', [overlaps; yield; purity]));

			set(hdPlot.inlet, 'YData', ppval(ppInlet, result.solution.time));
			set(hdPlot.titleRight, 'String', sprintf('Start %g Slope1 %g Length %g SC %g EC %g', x));

			set(hdPlot.opt(1), 'YData', [get(hdPlot.opt(1), 'YData'), -optimValues.fval], 'XData', [get(hdPlot.opt(1), 'XData'), optimValues.iteration]);
			set(hdPlot.opt(2), 'YData', [get(hdPlot.opt(2), 'YData'), optimValues.constrviolation], 'XData', [get(hdPlot.opt(2), 'XData'), optimValues.iteration]);
			set(hdPlot.opt(3), 'YData', [get(hdPlot.opt(3), 'YData'), optimValues.firstorderopt], 'XData', [get(hdPlot.opt(3), 'XData'), optimValues.iteration]);
			set(hdPlot.opt(4), 'YData', [get(hdPlot.opt(4), 'YData'), optimValues.stepsize], 'XData', [get(hdPlot.opt(4), 'XData'), optimValues.iteration]);
			set(hdPlot.optTitle, 'String', sprintf('Iteration %d', optimValues.iteration));

			for i = 1:numel(x)
				set(hdPlot.param(i), 'YData', [get(hdPlot.param(i), 'YData'), x(i)], 'XData', [get(hdPlot.param(i), 'XData'), optimValues.iteration]);
			end
		end
		drawnow;
	end
end

function modifyModelParams(sim, start, slope1, len)
%MODIFYMODELPARAMETERS Modifies the model parameters subject to given process parameters.

	% Check for vector input
	if nargin == 2
		len = start(3);
		slope1 = start(2);
		start = start(1);
	end

	bp = getBasicParams();

	% Set start and slope for second gradient (continuity requires that
	% start(grad2) = end(grad1).)
	start2 = start + slope1 * len;
	slope2 = (bp.maxSalt - start2) / (bp.endTime - len - bp.startTime);

	sim.setVariableParameterValues([start, slope1, start2, slope2, sim.sectionTimes(3) + len]);
end

function [sim] = createSimulator(colLength)
%CREATESIMULATOR Creates the model and simulator of the process and returns it
% The model parameters are taken from benchmark 2 of
% A. P??ttmann, S. Schnittert, U. Naumann & E. von Lieres (2013).
% Fast and accurate parameter sensitivities for the general rate model of
% column liquid chromatography.
% Computers & Chemical Engineering, 56, 46???57.
% doi:10.1016/j.compchemeng.2013.04.021

	bp = getBasicParams();

	% General rate model unit operation
	mGrm = SingleGRM();

	% Discretization
	mGrm.nComponents = 4;
	mGrm.nCellsColumn = 64; % Attention: This is low and only used for illustration (shorter runtime)
	mGrm.nCellsParticle = 16; % Attention: This is low and only used for illustration (shorter runtime)
	mGrm.nBoundStates = ones(mGrm.nComponents, 1); % Number of bound states for each component

	% Components are (in order): Salt, lysozyme, cytochrome, ribonuclease

	% Initial conditions, equilibrated empty column (note that solid phase salt
	% concentration has to match ionic capacity to satisfy equilibrium assumption)
	mGrm.initialBulk = [bp.initialSalt 0.0 0.0 0.0]; % [mol / m^3], also used for the particle mobile phase
	mGrm.initialSolid = [1.2e3 0.0 0.0 0.0]; % [mol / m^3]
		
	% Transport
	mGrm.dispersionColumn          = 5.75e-8; % [m^2 / s]
	mGrm.filmDiffusion             = [6.9e-6 6.9e-6 6.9e-6 6.9e-6]; % [m/s]
	mGrm.diffusionParticle         = [7e-10 6.07e-11 6.07e-11 6.07e-11]; % [m^2 / s]
	mGrm.diffusionParticleSurface  = [0.0 0.0 0.0 0.0]; % [m^2 / s]
	mGrm.interstitialVelocity      = 5.75e-4; % [m/s]

	% Geometry
	mGrm.columnLength        = colLength; % [m]
	mGrm.particleRadius      = 4.5e-5; % [m]
	mGrm.porosityColumn      = 0.37; % [-]
	mGrm.porosityParticle    = 0.75; % [-]
	
	% Adsorption
	mSma = StericMassActionBinding();
	mSma.kineticBinding = false; % Quasi-stationary binding (rapid-equilibrium)
	mSma.lambda     = 1.2e3; % Ionic capacity [mol / m^3]
	mSma.kA         = [0.0 35.5 1.59 7.7]; % Adsorption rate [(m^3 / mol)^nu / s]
	mSma.kD         = [0.0 1000 1000 1000]; % Desorption rate [(m^3 / mol)^nu / s]
	mSma.nu         = [0.0 4.7 5.29 3.7]; % Characteristic charge [-]
	mSma.sigma      = [0.0 11.83 10.6 10.0]; % Steric factor [-]
	mGrm.bindingModel = mSma;
	% The first value in the vectors above is ignored since it corresponds
	% to salt, which is component 0.
	% Note that due to the rapid-equilibrium assumption the equilibrium
	% constant is given by k_a / k_d.
	
	% Specify inlet profile

	% Reserve space: nSections x nComponents (a section can be thought of being a 
	% step in the process, see below)
	mGrm.constant       = zeros(4, mGrm.nComponents);
	mGrm.linear         = zeros(4, mGrm.nComponents);
	mGrm.quadratic      = zeros(4, mGrm.nComponents);
	mGrm.cubic          = zeros(4, mGrm.nComponents);

	% Section 1: Loading phase
	mGrm.constant(1, 1)  = bp.initialSalt;  % [mol / m^3] component 1 (salt)
	mGrm.constant(1, 2)  = 1.0;   % [mol / m^3] component 2
	mGrm.constant(1, 3)  = 1.0;   % [mol / m^3] component 3
	mGrm.constant(1, 4)  = 1.0;   % [mol / m^3] component 4

	% Section 2: Washing phase (no protein feed)
	mGrm.constant(2, 1)  = bp.initialSalt;  % [mol / m^3] component 1 (salt)

	% Section 3: Gradient 1 (linear salt gradient with step at the beginning)
	mGrm.constant(3, 1)  = 100;  % [mol / m^3] component 1 (salt)
	mGrm.linear(3, 1)    = 0.2;  % [mol / (m^3 * s)] component 1 (salt)

	% Section 4: Gradient 2 (linear salt gradient continuous with respect to first gradient)
	mGrm.constant(4, 1)  = mGrm.constant(3, 1) + ((bp.endTime - bp.startTime) * 0.5) * mGrm.linear(3, 1);  % [mol / m^3] component 1 (salt)
	mGrm.linear(4, 1)    = 0.5;  % [mol / (m^3 * s)] component 1 (salt)

	% Construct and configure simulator
	sim = Simulator.create();
	sim.solutionTimes = linspace(0, bp.endTime, bp.endTime+1); % [s], time points at which solution is computed
	sim.nThreads = 2; % Use 2 CPU cores for computation
	sim.initStepSize = 1e-9; % Initial time step size when beginning a new section
	sim.maxSteps = 100000; % Maximum number of (internal) time integrator steps

	% sectionTimes holds the sections and sectionContinuity indicates whether
	% the transition between two adjacent sections is continuous

	% Load, Wash, Gradient1, Gradient2
	sim.sectionTimes = [0.0, 10.0, bp.startTime, (bp.startTime + bp.endTime) * 0.5, bp.endTime]; % [s]
	sim.sectionContinuity = false(3, 1);

	% Hand model over to simulator	
	sim.model = mGrm;
end

function p = getBasicParams()
%GETBASICPARAMETERS Returns a struct with basic process parameters

	% Total process duration in s
	p.endTime = 6000;
	
	% Start time of first gradient in s
	p.startTime = 90;
	
	% Salt buffer concentration in mM for loading and washing
	p.initialSalt = 50;
	
	% Maximum salt buffer concentration in mM
	p.maxSalt = 1000;
end

% =============================================================================
%  
%  Copyright ?? 2015: Samuel Leweke??, Eric von Lieres??
%                                      
%    ?? Forschungszentrum Juelich GmbH, IBG-1, Juelich, Germany.
%  
%  All rights reserved. This program and the accompanying materials
%  are made available under the terms of the GNU Public License v3.0 (or, at
%  your option, any later version) which accompanies this distribution, and
%  is available at http://www.gnu.org/licenses/gpl.html
% =============================================================================
