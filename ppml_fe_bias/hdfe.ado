*! reghdfe 3.2.9 21feb2016
*! Sergio Correia (sergio.correia@duke.edu)


// Mata code is first, then main reghdfe.ado, then auxiliary .ado files

// -------------------------------------------------------------------------------------------------
// Mata Code: Method of Alternating Projections with Acceleration
// -------------------------------------------------------------------------------------------------
	// To debug the mata code, uncomment this three lines, and then -do- the file
	//discard
	//pr drop _all
	//clear all

* Type Aliases
	local Boolean 		real scalar
	local Integer 		real scalar
	local Real 			real scalar
	local Vector		real colvector
	local Matrix		real matrix
	local Series		real colvector // Should be N*1
	local Group			real matrix // Should be N*K
	local String 		string scalar
	local Varname 		string scalar
	local Varlist 		string rowvector // rowvector so they match tokens()
	local Problem		struct MapProblem scalar
	local FE			struct FixedEffect scalar
	local FunctionPointer pointer(`Group' function) scalar // Used for the Accelerate & Transform fns

// -------------------------------------------------------------------------------------------------
	
mata:
mata set matastrict on
	void assert_msg(real scalar t, | string scalar msg)
	{
		if (args()<2 | msg=="") msg = "assertion is false"
	        if (t==0) _error(msg)
	}
	
// -------------------------------------------------------------------------------------------------
// Structure of a Fixed Effect
// -------------------------------------------------------------------------------------------------

	struct FixedEffect {
		`Integer'	order 			// "g", the position in varlist
		`Varname'	varlabel		// Original label of this absvar
		`Integer'	num_slopes
		`Integer'	has_intercept
		`Integer'	levels			// Number of categories spanned by the ivars
		`Varlist'	ivars			// number of i.var elements
		`Varlist'	cvars			// number of c.var elements or slopes
		`Boolean'	is_sortedby		// 1 if the dataset is sorted by the ivars of this FE
		`Varname'	idvarname		// (optional) Name of variable with the absvar categories
		`Varlist'	target			// Name of the variable that will hold the estimates for the FE
		
		`Series'	p 				// Permutation vector
		`Series'	inv_p 			// Precompute invorder(p) because we'll use it a lot

		`Vector'	offsets			// Pos. of last obs. with that category (when sorted)
		`Vector'	counts			// number of obs. (weighted) with that value
		`Group'		x				// Vector/Matrix of (optionally demeaned) cvars
		`Matrix'	inv_xx			// Blocks of the inv(x'x) matrix; size KL*K (k=num_slopes, L=levels)
		`Matrix'	xmeans

		`Boolean'	is_clustervar, in_clustervar
		`Integer'	nesting_clustervar // Clustervar that nests this FE, if any

		// Temporary matrices for the stored FEs
		`Matrix'	alphas
		`Matrix'	tmp_alphas
	}
	
// -------------------------------------------------------------------------------------------------
// Structure of the MAP Problem
// -------------------------------------------------------------------------------------------------

struct MapProblem {
	struct FixedEffect vector fes	// The G*1 vector of FE structures
	`Integer'		G 				// Number of FEs when bunching slopes
	`Boolean'		has_intercept   // 1 if the model is not a pure-slope one
	`Varname'		weightvar 		// Name variable contaning the fw/pw/aw
	`String'		weighttype 		// fw/pw/aw
	`String'		weights 		// "[weighttype=weightvar]"
	`Series'		w 				// Contents of variable contaning the fw/pw/aw
	`Integer'		verbose			// Number of debug messages to show (0=None, 1=A little, 4=A *lot*)			
	`Integer'		N				// Number of obs; after map_precompute() the dataset CANNOT CHANGE!
	`Varlist'		keepvars		// By default we drop cvars and ivars ASAP; this prevents it (useful for clustervars and for timevar+panelvar under HAC errors)

	`Boolean'		will_save_fe	// True if at least one FE will be saved
	`Boolean'		keepsingletons	// If set to 1, it will not drop singletons (do not touch this!)

	`Integer'		C				// Number of cluster variables
	`Varlist'		clustervars
	`Varlist'		clustervars_original // Note: need to apply tokens()
	`Varname'		panelvar
	`Varname'		timevar
	`Boolean'		vce_is_hac

	`Boolean'		timeit
	`Varlist'		sortedby		// Variables on which the dataset is sorted (if anything)
	
	// Optimization parameters	
	`Integer'		poolsize 		// Group variables when demeaning (more is faster but uses more memory)
	`Real'			tolerance
	`Integer'		maxiterations
	`String'		transform		// Kaczmarz Cimmino Symmetric_kaczmarz (k c s)
	`String'		acceleration	// Acceleration method. None/No/Empty is none\
	`Integer'		accel_start		// Iteration where we start to accelerate // set it at 6? 2?3?
	
	// Specific to Aitken's acceleration
	`Integer'		accel_freq		
	`Integer'		stuck_threshold	// Call the improvement "slow" when it's less than e.g. 1%
	`Integer'		bad_loop_threshold	// If acceleration seems stuck X times in a row, pause it
	`Integer'		pause_length	// This is in terms of candidate accelerations, not iterations (i.e. x3)?

	// Temporary
	`Boolean'		storing_betas
	`Varname'		groupvar		// Name of the variable that will hold the mobility group
	`Varname'		grouptype		// Long, double, etc.
	`Varname'		grouplabel
	`Series'		groupseries		// The actual data of the mobility group variable
	`Series'		uid
	`Series'		resid
	`Varname'		residname
	`Integer'		num_iters_last_run
	`Integer'		num_iters_max

	// Temporary storage for DoFs
	`Integer'		dof_M
	`Integer'		dof_M_due_to_nested
	`Integer'		dof_KminusM
	`Integer'		dof_N_hdfe_extended
	`Vector'		doflist_M
	`Vector'		doflist_M_is_exact
	`Vector'		doflist_M_is_nested
	`Vector'		dof_SubGs
}
	
real rowvector safe_divide(real rowvector numerator, real rowvector denominator, | real scalar epsi) {
	 // If the denominator goes below machine precision, the division explodes
	 if (args()<3) epsi = epsilon(1)
	return( numerator :/ colmax(denominator \ J(1,cols(denominator),epsi)) )
}

// -------------------------------------------------------------------------------------------------

void verbose2local(`Problem' S, string scalar loc) {
	st_local(loc, strofreal(S.verbose))
}

// -------------------------------------------------------------------------------------------------

void function store_uid(`Problem' S, `Varname' varname) {
	S.uid = st_data(., varname)
	assert_msg(rows(S.uid)==S.N, "assertion failed: rows(S.uid)==S.N")
}

void function drop_uid(`Problem' S) {
	S.uid = J(0,0,.)
}

// -------------------------------------------------------------------------------------------------

void function store_resid(`Problem' S, `Varname' varname) {
	S.resid = st_data(., varname)
	S.residname = varname
	assert_msg(rows(S.resid)==S.N, "assertion failed: rows(S.resid)==S.N")
}

void function resid2dta(`Problem' S, `Boolean' original_dta, `Boolean' cleanup) {
	if (original_dta) {
		st_store(S.uid, st_addvar("double", S.residname), S.resid)
	}
	else {
		st_store(., st_addvar("double", S.residname), S.resid)
	}

	if (cleanup) {
		S.resid = J(0,0,.)
		S.residname = ""
	}	
}

// -------------------------------------------------------------------------------------------------

void function groupvar2dta(`Problem' S, | `Boolean' original_dta) {
	if (args()<2) original_dta = 1
	
	// If grouptype has not been set, that's because there was no need to
	// EG: Only one FE, or two FEs but one is the clustervar
	if (S.grouptype!="") {
		if (S.verbose>2) printf("{txt}    - Saving identifier for the first mobility group: {res}%s\n", S.groupvar)
		
		if (original_dta) {
			st_store(S.uid, st_addvar(S.grouptype, S.groupvar), S.groupseries)
			S.groupseries = J(0,0,0)
		}
		else {
			st_store(., st_addvar(S.grouptype, S.groupvar), S.groupseries)
		}

		st_varlabel(S.groupvar, S.grouplabel)
	}
	else {
		if (S.verbose>=0) printf("{txt}Note: mobility group not saved as there was no need to compute it (e.g. there are less than two absvars not nested within a cluster)\n")
	}
}

// -------------------------------------------------------------------------------------------------

void function drop_ids(`Problem' S) {
	`Integer' g
	for (g=1;g<=S.G;g++) {
		if (!S.fes[g].is_clustervar & S.fes[g].target=="") st_dropvar(S.fes[g].idvarname)
	}
}

// -------------------------------------------------------------------------------------------------

void function esample2dta(`Problem' S, `Varname' esample) {
	assert(length(S.uid)>0)
	st_store(S.uid, st_addvar("byte", esample), J(rows(S.uid),1,1) )
}

// -------------------------------------------------------------------------------------------------

// Copy the fixed effect estimates (the alphas back into the original dataset)
void function alphas2dta(`Problem' S) {
	`Integer' g, i
	`Varlist' target
	`String' varlabel
	assert(S.will_save_fe==1)
	if (S.verbose>1) printf("{txt}    - Storing fixed effects in the original dataset\n")
	for (g=1; g<=S.G; g++) {
		target = S.fes[g].target
		if (length(target)>0) {
			st_store(S.uid, st_addvar("double", target), S.fes[g].alphas)
			S.fes[g].alphas = J(0,0,0)
			for (i=1; i<=length(target);i++) {
				varlabel = invtokens(S.fes[g].ivars, "#")
				if (i>1 | !S.fes[g].has_intercept) varlabel = varlabel + "#c." + S.fes[g].cvars[i-S.fes[g].has_intercept]
				st_varlabel(target[i], sprintf("[FE] %s", varlabel))
			}
		}
	}
}
	
//  Parse absvars and initialize the almost empty MapProblem struct
`Problem' function map_init()
{
	`Integer'		g, G, num_slopes, has_intercept, i, H, j
	`Problem' 		S
	`Boolean'		auto_target // Automatically assign target names to all FEs
	`Varname'		basetarget
	`Varlist'		target, original_absvars, extended_absvars
	`String'		equation_d
	`Boolean'		equation_d_valid
	pointer(`FE') 	fe

	S.weightvar = S.weighttype = S.weights = ""
	S.verbose = 0
	S.transform = "symmetric_kaczmarz" // cimmino ?
	S.acceleration = "conjugate_gradient"
	S.tolerance = 1e-8
	S.maxiterations = 1e4
	S.accel_start = 6
	S.poolsize = 10

	// If clustering by timevar or panelvar and VCE is HAC, we CANNOT touch the clustervars to create compact ids!
	S.timevar = ""
	S.panelvar = ""
	S.vce_is_hac = 0

	// Specific to Aitken:
	S.accel_freq = 3
	S.pause_length = 20
	S.bad_loop_threshold = 1
	S.stuck_threshold = 5e-3
	S.N = .

	S.groupvar = "" // Initialize as empty
	S.grouptype = "" // Initialize as empty
	S.sortedby = "" // Initialize as empty (prevents bugs if we change the dataset before map_precompute)


	S.keepsingletons = 0
	S.G = G = st_numscalar("r(G)")
	S.has_intercept = st_numscalar("r(has_intercept)")
	S.C = 0
	S.clustervars = S.clustervars_original = J(0,0,"")
	S.fes = FixedEffect(G)
	S.will_save_fe = 0
	auto_target = st_numscalar("r(savefe)")
	assert(auto_target==1 | auto_target==0)
	if (auto_target) stata(sprintf("cap drop __hdfe*__*"))

	original_absvars = extended_absvars = J(1, G, "")

	for (g=1; g<=G; g++) {
		fe = &(S.fes[g])
		// recall a->b is the same as (*a).b
		num_slopes = st_numscalar(sprintf("r(num_slopes%f)",g))
		has_intercept = st_numscalar(sprintf("r(has_intercept%1.0f)",g))

		fe->order = g
		fe->num_slopes = num_slopes
		fe->has_intercept = has_intercept
		fe->varlabel = st_global(sprintf("r(varlabel%f)",g))
		fe->ivars = tokens(st_global( sprintf("r(ivars%f)",g) ))
		fe->cvars = tokens(st_global( sprintf("r(cvars%f)",g) ))
		fe->idvarname = sprintf("__ID%f__", g)
		fe->levels = .
		fe->target = J(0,0,"")
		fe->is_clustervar = 0
		fe->in_clustervar = 0
		fe->nesting_clustervar = .

		extended_absvars[g] = original_absvars[g] = invtokens(fe->ivars, "#")
		if (num_slopes>0) {
			original_absvars[g] = original_absvars[g] + (has_intercept ? "##c." : "#c.")
			original_absvars[g] = original_absvars[g] + (num_slopes==1 ? (fe->cvars) : "("+invtokens(fe->cvars)+")")
			
			extended_absvars[g] = (has_intercept ? extended_absvars[g] + " " : "") + invtokens(extended_absvars[g] + "#c." :+ (fe->cvars))
		}
			
		basetarget = st_global(sprintf("r(target%f)",g))
		if (basetarget=="" & auto_target) basetarget = sprintf("__hdfe%f__", g)
		if (basetarget!="") {
			S.will_save_fe = 1
			target = J(1, has_intercept + num_slopes, basetarget)
			if (has_intercept) stata(sprintf("confirm new variable %s", target[1]))
			for (i=1+has_intercept; i<=length(target); i++) {
				target[i] = target[i] + sprintf("_Slope%f", i-has_intercept)
				stata(sprintf("confirm new variable %s", target[i]))
			}
			fe->target = target
		}
	}

	equation_d_valid = 1
	equation_d = ""
	for (g=1; g<=S.G; g++) {
		H = S.fes[g].has_intercept + S.fes[g].num_slopes
		if (length(S.fes[g].target)==0) {
			equation_d_valid = 0
			break
		}
		assert(length(S.fes[g].target==H))

		j = 0
		for (i=1; i<=H;i++) {
			equation_d = equation_d + sprintf("%s%s", equation_d=="" ? "" : " + ", S.fes[g].target[i])
			if (i>1 | !S.fes[g].has_intercept) j++ // j is the cvar counter
			if (j>0) equation_d = equation_d + sprintf(" * %s", S.fes[g].cvars[j])
		}
	}
	if (equation_d_valid) st_global("r(equation_d)", invtokens(equation_d) )
	
	st_numscalar("r(will_save_fe)", S.will_save_fe)
	st_global("r(original_absvars)", invtokens(original_absvars) )
	st_global("r(extended_absvars)", invtokens(extended_absvars) )
	return(S)
}

void function map_init_clustervars(`Problem' S, `String' clustervars) {
	S.clustervars = S.clustervars_original = tokens(clustervars)
	S.C = length(S.clustervars)
}

void function map_init_weights(`Problem' S, `Varname' weightvar, `String' weighttype) {
	assert_msg(weightvar!="" & weighttype!="", "map_init_weights() requires weight var and type")
	stata(sprintf("confirm numeric variable %s, exact", weightvar))
	assert_msg(anyof(("fweight", "pweight", "aweight"), weighttype), "wrong weight type")
	S.weightvar = weightvar
	S.weighttype = weighttype
	S.weights = sprintf("[%s=%s]", weighttype, weightvar)
}

void function map_init_keepvars(`Problem' S, `Varname' keepvars) {
	//if (keepvars!="") stata(sprintf("confirm numeric variable %s, exact", keepvars))
	S.keepvars = tokens(keepvars)
}

void function map_init_transform(`Problem' S, `String' transform) {
	transform = strlower(transform)
	// Convert abbreviations
	if (strpos("cimmino", transform)==1) transform = "cimmino"
	if (strpos("kaczmarz", transform)==1) transform = "kaczmarz"
	if (strpos("symmetric_kaczmarz", transform)==1) transform = "symmetric_kaczmarz"
	if (strpos("rand_kaczmarz", transform)==1) transform = "random_kaczmarz" // experimental
	if (strpos("random_kaczmarz", transform)==1) transform = "random_kaczmarz" // experimental
	assert_msg(anyof(("cimmino","kaczmarz","symmetric_kaczmarz", "random_kaczmarz"),transform), "invalid transform")
	S.transform = transform
}

void function map_init_verbose(`Problem' S, `Integer' verbose) {
	assert_msg(round(verbose)==verbose, "verbose must be an integer")
	assert_msg(0<=verbose & verbose<=5, "verbose must be between 0 and 5")
	S.verbose = verbose
}

void function map_init_timeit(`Problem' S, `Integer' timeit) {
	assert_msg(timeit==0 | timeit==1, "timeit must be 0 or 1")
	S.timeit = timeit
}

void function map_init_poolsize(`Problem' S, `Integer' poolsize) {
	assert_msg(round(poolsize)==poolsize & poolsize>0, "poolsize must be a positive integer")
	S.poolsize = poolsize
}

void function map_init_panelvar(`Problem' S, `Varname' panelvar) {
	S.panelvar = panelvar
}

void function map_init_timevar(`Problem' S, `Varname' timevar) {
	S.timevar = timevar
}

void function map_init_groupvar(`Problem' S, `Varname' groupvar) {
	S.groupvar = groupvar
}

void function map_init_acceleration(`Problem' S, `String' acceleration) {
	acceleration = strlower(acceleration)
	// Convert abbreviations
	if (strpos("conjugate_gradient", acceleration)==1 | acceleration=="cg") acceleration = "conjugate_gradient"
	if (strpos("steepest_descent", acceleration)==1 | acceleration=="sd") acceleration = "steepest_descent"
	if (strpos("aitken", acceleration)==1) acceleration = "aitken"
	if (strpos("hybrid", acceleration)==1) acceleration = "hybrid" // experimental
	if (acceleration=="no" | acceleration=="none" | acceleration=="off") acceleration = "none"
	assert_msg(anyof(("conjugate_gradient","steepest_descent", "aitken", "none", "hybrid"),acceleration), "invalid acceleration")
	S.acceleration = acceleration
}

void function map_init_tolerance(`Problem' S, `Real' tolerance) {
	assert_msg(1e-16<=tolerance & tolerance<1, "tolerance must be in the range [1e-16, 1).")
	S.tolerance = tolerance
}

void function map_init_maxiterations(`Problem' S, `Integer' maxiterations) {
	assert_msg(round(maxiterations)==maxiterations, "maxiterations must be an integer")
	assert_msg(maxiterations>0, "maxiterations must be positive")
	S.maxiterations = maxiterations
}

void function map_init_keepsingletons(`Problem' S, `Boolean' keepsingletons) {
	assert_msg(keepsingletons==0 | keepsingletons==1, "keepsingletons must be 0 or 1")
	S.keepsingletons = keepsingletons
}

void function map_init_vce_is_hac(`Problem' S, `Boolean' vce_is_hac) {
	assert_msg(vce_is_hac==0 | vce_is_hac==1, "vce_is_hac must be 0 or 1")
	S.vce_is_hac = vce_is_hac
}
	
void function map_precompute(`Problem' S) {
	`Integer' i, g, h, value
	`Varlist' keepvars, cl_ivars
	transmorphic counter, loc
	`Varname' key
	`String' all_clustervars
	`Boolean' has_intercept
	if (S.verbose>0) printf("\n{txt}{bf:mata: map_precompute()}\n")

	// Warn if there are no fixed intercepts (i.e. heterogeneous intercepts)
	has_intercept = 0
	for (g=1; g<=S.G; g++) {
		if (S.fes[g].has_intercept) has_intercept = 1
	}
	if (has_intercept==0) printf("{txt}(WARNING: no intercepts terms in absorb(); regression lacks constant term)\n")

	// Count how many times each var is used, so we can drop them when the counter reaches zero
	counter = asarray_create()
	asarray_notfound(counter, 0)
	// Variables passed through map_init_keepvars()
	keepvars = S.keepvars
	// ivars and cvars of the FEs
	for (g=1; g<=S.G; g++) {
		keepvars = keepvars, S.fes[g].ivars , S.fes[g].cvars
	}
	// Weight var
	if (S.weightvar!="") keepvars = keepvars, S.weightvar
	// Cluster vars
	for (h=1; h<=S.C; h++) {
		cl_ivars = tokens(S.clustervars[h], "#")
		cl_ivars = select(cl_ivars, cl_ivars:!="#")
		keepvars = keepvars, cl_ivars
	}
	// Time and panel vars
	if (S.vce_is_hac & S.timevar!="") keepvars = keepvars, S.timevar
	if (S.vce_is_hac & S.panelvar!="") keepvars = keepvars, S.panelvar

	// Fill
	for (i=1; i<=length(keepvars); i++) {
		asarray(counter, keepvars[i], asarray(counter, keepvars[i])+1)
	}

	// Report
	if (S.verbose>3) printf("{txt}{bf: 0. Usage count of each variable (dropped if it reaches zero)}\n")
	for (i=1; i<=asarray_elements(counter); i++) {
		if (S.verbose>3) printf("{txt}    - key=%s {col 30}count=%f\n", keepvars[i], asarray(counter,keepvars[i]))
	}

	// 0. Store sort order (used in steps 1 and 3)
	S.sortedby = tokens(st_macroexpand("`" + ": sortedby" + "'"))

	// 1. Store permutation vectors and their invorder, generate ID variables, drop singletons
	if (S.verbose>0) printf("{txt}{bf: 1. Storing permutation vectors, generating ids, dropping singletons}\n")
	if (S.timeit) timer_on(21)
	map_precompute_part1(S, counter)
	if (S.timeit) {
		timer_off(21)
		printf("{res}{col 20}%6.3f{txt}{col 30}precompute 1 (sorts, ids, drop singletons)\n", timer_value(21)[1])
		timer_clear(21)
	} 

	// 2. Store group offsets, group counters; demeaned(x), inv(xx) if num_slopes>0; weightvars
	if (S.verbose>0) printf("{txt}{bf: 2. Storing counters and offsets; processing cvars}\n")
	if (S.timeit) timer_on(22)
	map_precompute_part2(S, counter)
	if (S.timeit) {
		timer_off(22)
		printf("{res}{col 20}%6.3f{txt}{col 30}precompute 2 (counters, offsets, cvars)\n", timer_value(22)[1])
		timer_clear(22)
	} 

	// 3. Create cluster IDs, report whether is/in/nested wrt cluster; store precomputed inv(p)
	if (S.verbose>0) printf("{txt}{bf: 3. Storing reverse permutation vectors, creating cluster IDs}\n")
	if (S.timeit) timer_on(23)
	map_precompute_part3(S, counter)
	if (S.timeit) {
		timer_off(23)
		printf("{res}{col 20}%6.3f{txt}{col 30}precompute 3 (reverse permutations, cluster ids)\n", timer_value(23)[1])
		timer_clear(23)
	} 

	// 4. Keep only the essential variables
	keepvars  = J(1,0,"")
	for (loc=asarray_first(counter); loc!=NULL; loc=asarray_next(counter, loc)) {
		key = asarray_key(counter, loc)
		value = asarray_contents(counter, loc)
		if (value>0) keepvars = keepvars, key
	}
	if (S.verbose>3) printf("{txt}{bf: 4. Keeping the following variables}")
	st_keepvar(keepvars)
	// if (S.verbose>3) printf("\n{txt}    %s\n", invtokens(keepvars))
	if (S.verbose>3) stata("describe _all, numbers") // This resets r(..)!
	if (S.verbose>3) printf("\n")

	// Store N (todo: add other details) to ensure the dataset doesn't change from now on
	S.N = st_nobs()

	// Store updated clustervars (run after describe!)
	for (h=1; h<=S.C;h++) {
		all_clustervars = all_clustervars, S.clustervars[h]
	}
	st_rclear()
	st_global("r(updated_clustervars)", invtokens(all_clustervars))
}
	
void map_precompute_part1(`Problem' S, transmorphic counter) {

	`Integer' G, i, j, n, g, h, i_last_singleton, num_singletons, initial_N
	`Boolean' sortedby
	`Group' id
	`Series' singleton, sum_singleton, inv_p
	`Varlist' idvarnames
	string scalar vartype
	pointer(`Series') scalar pp // Just to shorten code

	G = length(S.fes)
	i = i_last_singleton = g = 1

	// Give huge warning if keeping singletons
	if (S.keepsingletons) printf(`"{txt}(WARNING: singletons are not dropped; statistical significance might be biased {browse "http://scorreia.com/reghdfe/nested_within_cluster.pdf":[link]})\n"')

	initial_N = st_nobs()

	// Loop until we stop discovering singletons (and then a bit more to be sure; G-1 to be exact)
	while (i<i_last_singleton+G) {
		if (g>G) g = 1
		if (S.verbose>1) printf("{txt}    - i=%f (g=%f/%f)\t(N=%f)\t", i, g, G, st_nobs())

		idvarnames = i<=G ? S.fes[g].ivars : S.fes[g].idvarname
		id = st_data(., idvarnames) // 2% of runtime
		if (i<=G) {
			for (j=1; j<=length(idvarnames); j++) {
				n = asarray(counter, idvarnames[j]) - 1
				asarray(counter, idvarnames[j], n)
				if (n==0) {
					st_dropvar(idvarnames[j])
				}
			}
		}
		if (i<=G) S.fes[g].is_sortedby = already_sorted(S, idvarnames)
		sortedby = S.fes[g].is_sortedby
		if (i<=G & !sortedby) {
			if (S.timeit) timer_on(31)
			S.fes[g].p = order( id , 1..length(idvarnames) ) // 55% of function time
			if (S.timeit) {
				timer_off(31)
				printf("{res}{col 30}%6.3f{txt}{col 40}mata order()\n", timer_value(31)[1])
				timer_clear(31)
			} 
		}

		if (!sortedby) {
			_collate(id, S.fes[g].p) // sort id by p // 12% of function time
			inv_p = invorder(S.fes[g].p) // construct inv(p) that we'll use later
		}

		// Note that the lhs is actually the deltas, as in "bys id: gen delta = _n==1"
		id = rows_that_change(id) // 7% of function time
		if (!S.keepsingletons) singleton = select_singletons(id) // 5% of function time

		// Save IDs in dataset before dropping observations
		id = S.keepsingletons ? runningsum(id) : runningsum(id :* !singleton) // this is the ID now, not the deltas anymore
		S.fes[g].levels = id[length(id)]
		vartype = S.fes[g].levels<=100 ? "byte" : (S.fes[g].levels<=32740? "int" : "long")
		if (i<=G) {
			st_store(., st_addvar(vartype, S.fes[g].idvarname), sortedby? id : id[inv_p])
		}
		else {
			st_store(., S.fes[g].idvarname, sortedby? id : id[inv_p])
		}

		num_singletons = S.keepsingletons ? 0 : sum(singleton)
		if (num_singletons>0) {
			if (S.verbose>1) printf("{txt}(%f singletons)", num_singletons)
			i_last_singleton = i

			// Sort -singleton- as in the dataset, and use it to drop observations
			// 5% of function time
			singleton = sortedby? singleton : singleton[inv_p]
			st_dropobsif(singleton)
			if (!st_nobs()) {
				printf("{err}\nno observations left after dropping singletons (%f obs. dropped)\n", initial_N)
				exit(error(2001))
			}

			// But now our precious sort orders (the p's) are useless! Fix them
			sum_singleton = runningsum(singleton)
			for (h=1;h<=G & h<=i; h++) { // 6% of function time
				if (S.fes[h].is_sortedby) continue
				pp = &(S.fes[h].p)
				(*pp) = select(*pp - sum_singleton[*pp] , !singleton[*pp] )
			}
		}

		if (S.verbose>1) printf("{txt}\n")
		i++
		g++
	}

	if (initial_N>st_nobs()) printf("{txt}(dropped %f singleton observations)\n", initial_N-st_nobs())
}

// -------------------------------------------------------------
// ALREADY_SORTED:
// -------------------------------------------------------------
`Integer' already_sorted(`Problem' S, string vector vars) {
	return(length(vars) > length(S.sortedby) ? 0 : vars==S.sortedby[1..length(vars)])
}

// -------------------------------------------------------------
// ROWS_THAT_CHANGE: Return a 0/1 vector indicating what are diff from the previous row
// -------------------------------------------------------------
	// Idea: compromise between doing the operation in one go (uses lots of memory) vs doing loops (2x slower)
	// Other alternatives: loop row-by-row (slower), loop col-by-col and take max() (slower)
`Vector' rows_that_change(`Matrix' input) {
	`Vector' ans
	`Integer' i, j, K, N, stepsize
	
	// Size of blocks of matrices used (larger=faster smaller=less memory)
	// Benchmarks with 3 unsorted ivars showed 1e4 was fastest, followed by 1e3 and then 1e5
	stepsize = 1e4

	N = rows(input)
	K = cols(input)
	ans = J(N,1,0)
	ans[1] = 1
	for (i=2; i<=N;i=i+stepsize) {
		j = min((i+stepsize-1, N))
		ans[|i\j|] = rowmax(input[|i-1,1\j-1,K|] :!= input[|i,1\j,K|])
	}
	return(ans)
}

// -------------------------------------------------------------
// SELECT_SINGLETONS: 
// -------------------------------------------------------------
`Vector' select_singletons(`Vector' input) {
	// Code modified from <rows_that_change>
	`Vector' ans
	`Integer' i, j, N, stepsize

	// Size of blocks of matrices used (larger= hopefully faster, but smaller=less memory)
	// Benchmarks with 3 unsorted ivars showed 1e4 was fastest, followed by 1e3 and then 1e5
	stepsize = 1e4

	N = rows(input)
	ans = J(N,1,0)
	for (i=1; i<=N-1;i=i+stepsize) {
		j = min((i+stepsize-1, N-1))
		// We need that ans[i]==1 and ans[i+1]==1
		// Since ans is either 0 or 1, this is equivalent to
		ans[|i\j|] = (input[|i\j|] + input[|i+1\j+1|] :== 2) 
	}
	ans[N] = (input[N]==1) // Special case, last obs is singleton if it's the first obs in the group
	return(ans)
}
	
void map_precompute_part2(`Problem' S, transmorphic counter) {
	`Integer' G, g, k, K, n
	real scalar stdev
	`Boolean' sortedby
	`Series' id

	G = length(S.fes)
	if (S.weightvar!="") S.w = st_data(., S.weightvar)

	for (g=1; g<=G; g++) {
		sortedby = S.fes[g].is_sortedby
		K = S.fes[g].num_slopes
		assert(K==length(S.fes[g].cvars))
		if (S.verbose>1) printf("{txt}    - g=%f/%f\t\t(K=%f)\n", g, G, K)
		
		id = st_data(., S.fes[g].idvarname)
		if (!sortedby) id = id[S.fes[g].p]

		// Store offsets, counts (optionally weighted)
		S.fes[g].counts = count_by_group(id) // this line accounts for 95% of the runtime of map_precompute_part2()
		S.fes[g].offsets = runningsum(S.fes[g].counts)
		if (S.weightvar!="") S.fes[g].counts = count_by_group(id, sortedby? S.w : S.w[S.fes[g].p])

		// Store cvars and related structures
		if (K>0) {

			// Store the cvars
			S.fes[g].x = st_data(., S.fes[g].cvars)

			// Drop cvars from dataset if not needed anymore
			for (k=1; k<=K; k++) {
				n = asarray(counter, S.fes[g].cvars[k]) - 1
				asarray(counter, S.fes[g].cvars[k], n)
				if (n==0) {
					st_dropvar(S.fes[g].cvars[k])
				}
			}

			// Sort the cvars if needed
			if (!sortedby) S.fes[g].x = S.fes[g].x[S.fes[g].p,]

			// Standardize
			// BUGBUG: Check that results don't change; specially on corner cases
			// EG: weights, no intercept, intercept, only one slope, etc.
			for (k=1; k<=K; k++) {
				// BUGBUG
				stdev = 1 // sqrt(quadvariance(S.fes[g].x[., k]))
				if (stdev<1e-5) stdev = 1e-5 // Reduce accuracy errors
				S.fes[g].x[., k] = S.fes[g].x[., k] :/ stdev
			}

			// Demean X and precompute inv(X'X) (where X excludes the constant due to demeaning, if applicable)
			// Note that the demeaning is done directly in the S. structure
			S.fes[g].inv_xx = demean_and_compute_invxx(S, g)
		} // end of slope part
	
	} // next g
}

// -------------------------------------------------------------
// COUNT_BY_GROUP: alternative to mm_freq(group) (~10% of runtime)
// -------------------------------------------------------------
// Assume -id- (groups) and -w- (the weights) are sorted by id!
`Vector' function count_by_group(`Series' id, | `Series' w)
{
	`Integer' i, j, obs, levels, count
	`Boolean' has_weights
	`Vector' ans

	obs = rows(id)
	levels = id[length(id)]
	assert_msg(obs>levels, "Error: more levels of FE than observations!")
	has_weights = args()>1

	ans = J(levels, 1, 0)
	count = 0

	// Avoid conditional op. within loop as it gets *really* slow
	// <i> indexes observations, <j> indexes groups
	if (has_weights) {
		for (i=j=1; i<=obs; i++) {
			if (id[i]>j) {
				ans[j++] = count
				count = 0
			}
			count = count + w[i]
		}
	}
	else {
		for (i=j=1; i<=obs; i++) {
			if (id[i]>j) {
				ans[j++] = count
				count = 0
			}
			++count
		}
	}

	ans[j] = count // Last group
	assert( all(ans) ) // Counts *must* be positive for all levels
	return(ans)
}

// -------------------------------------------------------------
// DEMEAN_AND_COMPUTE_INVXX
// -------------------------------------------------------------
`Matrix' function demean_and_compute_invxx(`Problem' S, `Integer' g) {

	// j iterates over LEVELS; i iterates over OBS
	`Integer'	K, L, j, i_lower, i_upper
	`Boolean'	has_weights, sortedby, has_intercept
	`Matrix'	ans, tmp_x
	`Vector'	w, tmp_w
	real scalar	tmp_count
	K = S.fes[g].num_slopes // Exclude intercept
	L = S.fes[g].levels
	ans = J(L*K, K, 0)
	has_weights = S.weightvar !=""
	sortedby = S.fes[g].is_sortedby
	has_intercept = S.fes[g].has_intercept

	if (has_weights) {
		w = sortedby ? S.w : S.w[S.fes[g].p]
		assert(rows(w)==rows(S.fes[g].x))
	}

	if (has_intercept) S.fes[g].xmeans = J(L, K, .)
	
	i_lower = 1
	for (j=1; j<=L; j++) {
		i_upper = S.fes[g].offsets[j]
		tmp_count = S.fes[g].counts[j]
		tmp_w = has_weights ? w[| i_lower \ i_upper |] : 1
		tmp_x = S.fes[g].x[| i_lower , 1 \ i_upper , . |]
		if (has_intercept) {
			S.fes[g].xmeans[j, .] = quadcolsum(has_weights ? tmp_x :* tmp_w : tmp_x) / tmp_count
			S.fes[g].x[| i_lower , 1 \ i_upper , . |] = tmp_x = tmp_x :- S.fes[g].xmeans[j, .]
		}
		ans[| 1+(j-1)*K , 1 \ j*K , . |] = invsym(quadcross(tmp_x, tmp_w, tmp_x))
		i_lower = i_upper + 1

		// BUGBUG: quadcolsum???? quadcross????
		// use crossdev(x,means,w,x,means) if we don't demean beforehand
	}
	return(ans)
}
	
void map_precompute_part3(`Problem' S, transmorphic counter) {
	`Integer' g, h, i, j, n, L, i_lower, i_upper
	`Varname' var
	`Boolean' done, is_nested, sortedby, hac_exception
	`Vector' need_to_create_clustervar, range
	`Varlist' sorted_fe_ivars, sorted_cl_ivars, cl_ivars
	`String' vartype
	`Group' id
	`Series' p, sorted_cl_id

	need_to_create_clustervar = J(S.C, 1, 1)

	for (g=1;g<=S.G;g++) {
		S.fes[g].inv_p = invorder(S.fes[g].p)
		var = S.fes[g].idvarname
		st_varlabel(var, sprintf("[ID] %s", S.fes[g].varlabel))
		asarray(counter, var, asarray(counter, var)+1)

		done = 0
		sorted_fe_ivars = sort(S.fes[g].ivars', 1)'

		// 1. Check if the FE has the same ivars as a cluster (is_clustervar=1)
		for (h=1; h<=S.C;h++) {
			sorted_cl_ivars = tokens(S.clustervars[h], "#")
			sorted_cl_ivars = sort(select(sorted_cl_ivars, sorted_cl_ivars:!="#")', 1)'
			hac_exception = (sorted_cl_ivars==S.panelvar | sorted_cl_ivars==S.timevar) & S.vce_is_hac
			if (sorted_fe_ivars==sorted_cl_ivars & !hac_exception) {
				need_to_create_clustervar[h] = 0
				S.clustervars[h] = var
				st_varlabel(var, sprintf("[CLUSTER] %s", st_varlabel(var)))
				S.fes[g].is_clustervar = 1
				done = 1
				break
			}
		}
	}

	// Create the cluster IDs if needed
	for (h=1; h<=S.C;h++) {
		cl_ivars = tokens(S.clustervars_original[h], "#")
		cl_ivars = select(cl_ivars, cl_ivars:!="#")
		
		
		for (j=1; j<=length(cl_ivars); j++) {
			n = asarray(counter, cl_ivars[j]) - 1
			assert_msg(n>=0, sprintf("counter[%s] was negative", cl_ivars[j]))
			asarray(counter, cl_ivars[j], n)
		}
		
		if (!need_to_create_clustervar[h]) continue
		if (cl_ivars==S.panelvar & S.vce_is_hac) continue
		if (cl_ivars==S.timevar  & S.vce_is_hac) continue

		id = st_data(., cl_ivars)

		// Construct and save cluster ID
		sortedby = already_sorted(S, cl_ivars)
		p = order( id , 1..length(cl_ivars) )
		if (!sortedby) {
			_collate(id, p) // sort id by p // 12% of function time
		}
		id = runningsum(rows_that_change(id))
		L = id[rows(id)]
		vartype = L<=100 ? "byte" : (L<=32740? "int" : "long")
		S.clustervars[h] = sprintf("__CL%f__", h)
		asarray(counter, S.clustervars[h], asarray(counter, S.clustervars[h])+1)
		st_store(., st_addvar(vartype, S.clustervars[h]), sortedby ? id : id[invorder(p)])
		st_varlabel(S.clustervars[h], sprintf("[CLUSTER] %s", S.clustervars_original[h]))
	}

	for (g=1;g<=S.G;g++) {
		var = S.fes[g].idvarname
		if (S.fes[g].is_clustervar) continue
		done = 0
		sorted_fe_ivars = sort(S.fes[g].ivars', 1)'

		// 2. Check if the FE ivars are a superset of those of the cluster (in_clustervar=1)
		for (h=1; h<=S.C;h++) {
			sorted_cl_ivars = tokens(S.clustervars_original[h], "#")
			sorted_cl_ivars = sort(select(sorted_cl_ivars, sorted_cl_ivars:!="#"), 1)
			if (length(sorted_cl_ivars)>=length(sorted_fe_ivars)) continue
			is_nested = 1
			for (i=1;i<=length(sorted_cl_ivars);i++) {
				if (!anyof(sorted_fe_ivars, sorted_cl_ivars[i])) {
					is_nested = 0
					break
				}
			}
			if (is_nested) {
				S.fes[g].in_clustervar = 1
				S.fes[g].nesting_clustervar = h
				done = 1
				break
			}
		}
		if (done) continue

		// 3. Check if the FE is nested within a cluster (e.g. cluster=state FE=zipcode)
		L = S.fes[g].levels
		for (h=1; h<=S.C; h++) {
			sorted_cl_id = st_data(., S.clustervars[h])
			if (!S.fes[g].is_sortedby) sorted_cl_id = sorted_cl_id[S.fes[g].p]
			i_lower = 1
			is_nested = 1
			for (j=1; j<=L; j++) {
				i_upper = S.fes[g].offsets[j]
				range = minmax(sorted_cl_id[| i_lower , 1 \ i_upper , . |])
				i_lower = i_upper + 1
				if (range[1]!=range[2]) {
					is_nested = 0
					break
				}
			}
			if (is_nested) {
				S.fes[g].in_clustervar = 1
				S.fes[g].nesting_clustervar = h
				break
			}
		}
	}
}
	
`Group' function map_projection(`Problem' S, `Integer' g, `Group' y) {
	`Integer' 	K, L, Q // Q is the number of depvars
	`Integer' 	j, i_lower, i_upper // j loops over levels, i loops over observations
	`Boolean' 	has_weights, sortedby, has_intercept, storing_betas
	`Series'	sorted_w
	`Group'		ans
	`Vector'	tmp_w, tmp_count
	real rowvector b
	real rowvector ymean, alpha // 1*Q
	real rowvector zero // 1*K
	`Matrix'	tmp_y, tmp_x
	pointer(`Series') scalar p_sorted_w
	pragma unset sorted_w // If we just set the pointer, what happens to the underlying data?

	// PROFILE TO SEE IF THIS HELPS OR NOT AT ALL
	//pointer(`Vector') scalar p_offset
	//p_offset = &(S.fes[g].offsets)

	has_weights = S.weightvar !=""
	sortedby = S.fes[g].is_sortedby
	has_intercept = S.fes[g].has_intercept
	K = S.fes[g].num_slopes
	Q = cols(y)
	L = S.fes[g].levels
	tmp_w = 1 // Harmless value for when there are no weights

	// Minimize copy+order operations on y
	if (has_weights) p_sorted_w = sortedby ? &(S.w) : &(sorted_w = S.w[S.fes[g].p, .])
	if (K>0) zero = J(1,K,0)

	ans = sortedby ? y : y[S.fes[g].p, .]

	i_lower = 1
	storing_betas = S.storing_betas & length(S.fes[g].target)>0
	for (j=1; j<=L; j++) {
		i_upper = S.fes[g].offsets[j]
		tmp_count = S.fes[g].counts[j]
		
		if (has_weights) tmp_w = (*p_sorted_w)[| i_lower \ i_upper |]
		tmp_y = ans[| i_lower , 1 \ i_upper , . |]
		// BUGBUG: quadcolsum or colsum ? Depends if there are dense FEs. Maybe condition it on L??
		if (has_weights) {
			ymean = has_intercept ? (quadcolsum(tmp_y :* tmp_w) / tmp_count) : 0
		}
		else {
			ymean = has_intercept ? (quadcolsum(tmp_y) / tmp_count) : 0
		}

		if (K>0) {
			tmp_x = S.fes[g].x[| i_lower , 1 \ i_upper , . |]
			// BUGBUG crossdev/cross or their quad version?
			if (has_intercept) {
				b = S.fes[g].inv_xx[| 1+(j-1)*K , 1 \ j*K , . |] * quadcrossdev(tmp_x, zero, tmp_w, tmp_y, ymean)
				alpha = ymean - S.fes[g].xmeans[j, .] * b
			}
			else {
				b = S.fes[g].inv_xx[| 1+(j-1)*K , 1 \ j*K , . |] * quadcross(tmp_x, tmp_w, tmp_y)
			}
		}
		
		if (storing_betas) {
			if (has_intercept) S.fes[g].tmp_alphas[j, 1] = K==0 ? ymean : alpha
			if (K>0) S.fes[g].tmp_alphas[j, (has_intercept+1)..(has_intercept+K) ] = b'
		}

		// BUGBUG if we split this ternary will it be faster?
		//ans[| i_lower , 1 \ i_upper , . |] = K>0 ? (ymean :+ tmp_x*b) : (ymean :+ J(i_upper-i_lower+1,Q,0))
		if (K==0) {
			ans[| i_lower , 1 \ i_upper , . |] = ymean :+ J(i_upper-i_lower+1,Q,0)
		}
		else if (has_intercept) {
			ans[| i_lower , 1 \ i_upper , . |] = ymean :+ tmp_x*b
		}
		else {
			ans[| i_lower , 1 \ i_upper , . |] = tmp_x*b
		}


		i_lower = i_upper + 1
	}
		
	return(sortedby ? ans : ans[S.fes[g].inv_p, .])
}
	
void function map_solve(`Problem' S, `Varlist' vars, | `Varlist' newvars, `Boolean' restore_dta) {

	`Integer' i, j, h, Q
	`Group' y, residuals
	`Varlist'	chars
	real rowvector stdevs
	`FunctionPointer' transform, accelerate

	if (S.verbose>0) printf("{txt}{bf:mata: map_solve()}\n")
	assert_msg(S.N!=., "map_solve() needs to be run after map_precompute()")
	assert_msg(S.N==st_nobs(), "dataset cannot change after map_precompute()")
	S.storing_betas = 0

	if (S.verbose>0) printf("{txt} - Loading variables into Mata\n")
	vars = tokens(vars)
	Q = cols(vars)

	// Store chars var[name] that contain the original varname (e.g. L.var)
	chars = J(1, Q, "")
	for (i=1;i<=Q;i++) {
		chars[i] = st_global(sprintf("%s[name]", vars[i]))
	}

	// Optional arguments
	newvars = (args()<3 | newvars=="") ? vars : tokens(newvars)
	assert_msg(length(vars)==length(newvars), "map_solve error: newvars must have the same size as vars")
	if (args()<4) restore_dta = 0 // restore dataset (only for hdfe.ado)
	assert_msg(restore_dta==0 | restore_dta==1, "restore_dta must be 0 or 1")
	
	// Solver Warnings
	if (S.transform=="kaczmarz" & S.acceleration=="conjugate_gradient") {
		printf("{err}(WARNING: convergence is {bf:unlikely} with transform=kaczmarz and accel=CG)\n")
	}

	// Load transform pointer
	if (S.transform=="cimmino") transform = &transform_cimmino()
	if (S.transform=="kaczmarz") transform = &transform_kaczmarz()
	if (S.transform=="symmetric_kaczmarz") transform = &transform_sym_kaczmarz()
	if (S.transform=="random_kaczmarz") transform = &transform_rand_kaczmarz()

	// Pointer to acceleration routine
	if (S.acceleration=="none") accelerate = &accelerate_none()
	if (S.acceleration=="conjugate_gradient") accelerate = &accelerate_cg()
	if (S.acceleration=="steepest_descent") accelerate = &accelerate_sd()
	if (S.acceleration=="aitken") accelerate = &accelerate_aitken()
	if (S.acceleration=="hybrid") accelerate = &accelerate_hybrid()

	// Shortcut for trivial case (1 FE)
	if (S.G==1) accelerate = &accelerate_none()

	// Iterate on variables grouped by poolsize: subset = data[i..j]
	S.num_iters_max = 0
	if (restore_dta) residuals = J(S.N, 0, .)

	for (i=1;i<=Q;i=i+S.poolsize) {
		
		j = i + S.poolsize - 1
		if (j>Q) j = Q

		// Load data
		y = st_data(., vars[i..j])
		
		// Drop loaded vars as quickly as possible (also they might not even be -double-)
		st_dropvar(vars[i..j])
		
		// Standardize variables
		if (S.verbose>0) printf("{txt} - Standardizing variables\n")
		stdevs = J(1, cols(y), .)
		for (h=1; h<=cols(y); h++) {
			stdevs[h] = max((  sqrt(quadvariance(y[., h])) , sqrt(epsilon(1)) ))
		}
		y = y :/ stdevs

		// Solve!		
		if (S.verbose>0) printf("{txt} - Solving problem (acceleration={res}%s{txt}, transform={res}%s{txt} tol={res}%-1.0e{txt} poolsize={res}%f{txt} varsize={res}%f{txt})\n", S.acceleration, S.transform, S.tolerance, S.poolsize, cols(y))
		if (S.verbose>1) printf("{txt} - Variables: {res}" + invtokens(vars[i..j])+"{txt}\n")
		y = (*accelerate)(S, y, transform) :* stdevs
		if (S.num_iters_last_run>S.num_iters_max) S.num_iters_max = S.num_iters_last_run
		
		// Return residuals
		if (restore_dta) {
			residuals = residuals , y
		}
		else {
			if (S.verbose>1) printf("{txt} - Saving transformed variables\n")
			st_store(., st_addvar("double", newvars[i..j]), y)
		}
		y = J(0,0,.) // clear space (not really needed)

	}

	// this is max(iter) across all vars
	if (S.verbose==0) printf("{txt}(converged in %g iterations)\n", S.num_iters_max)

	// Restore dataset; used by hdfe.ado with generate() instead of clear
	if (restore_dta) {
		stata("restore")
		st_store(S.uid, st_addvar("double", newvars), residuals)
		residuals = J(0,0,.) // clear space (not really needed)
	}

	// Add chars with original names to new variables
	for (i=1;i<=Q;i++) {
		st_global(sprintf("%s[name]", newvars[i]), chars[i])
	}

}
	
void function map_save_fe(`Problem' S, `Varname' sum_fe) {

	// Storing FEs and returning them requires 6 changes
	// 1) Extend the S and FE structures (add S.storing_betas, FE.alphas FE.tmp_alphas)
	// 2) Allocate them here
	// 3) Return results at the end of this function
	// 4) Within the accelerators, modify the SD to update the alphas
	// 5) Within map_projection, add a conditional to update tmp_alphas if needed

	`Integer' 	g
	`Vector' 	y
	`Varlist'	target

	if (S.verbose>0) printf("{txt}{bf:mata: map_save_fe()}\n")
	assert_msg(S.N!=., "map_save_fe() needs to be run after map_precompute()")
	assert_msg(S.N==st_nobs(), "dataset cannot change after map_precompute()")

	if (S.verbose>0) printf("{txt} - Loading variable into Mata\n")
	assert_msg(length(tokens(sum_fe))==1, "sum_fe should be a varname, not a varlist")
	y = st_data(., sum_fe)
	
	st_dropvar(sum_fe)
	
	if (S.verbose>0) printf("{txt} - Allocating objects to save the fixed effect estimates\n")
	S.storing_betas = 1
	for (g=1; g<=S.G; g++) {
		if (length(S.fes[g].target)>0) {
			S.fes[g].alphas = S.fes[g].tmp_alphas = 
				J(S.fes[g].levels, S.fes[g].has_intercept + S.fes[g].num_slopes, 0)
		}
	}

	// No need to standardize b/c it's only one variable
	if (S.verbose>0) printf("{txt} - Solving problem (acceleration={res}%s{txt}, transform={res}%s{txt} tol={res}%-1.0e{txt} poolsize={res}%f{txt} varsize={res}%f{txt})\n", "steepest_descent", "kaczmarz", S.tolerance, S.poolsize, 1)

	y = accelerate_sd(S, y, &transform_kaczmarz())
	if (S.verbose==0) printf("{txt}(converged in %g iterations)\n", S.num_iters_last_run)
	
	if (S.verbose>1) printf("{txt} - Saving transformed variable\n")
	st_store(., st_addvar("double", sum_fe), y)
	y = J(0,0,.) // clear space

	// Store FEs
	if (S.verbose>1) printf("{txt} - Saving fixed effects\n")
	for (g=1; g<=S.G; g++) {
		target = S.fes[g].target
		if (length(target)>0) {
			S.fes[g].tmp_alphas = J(0,0,.)
			S.fes[g].alphas = S.fes[g].alphas[ st_data(., S.fes[g].idvarname) , . ]
		}
	}
}
	
// -------------------------------------------------------------------------------------------------
// Acceleration Schemes
// -------------------------------------------------------------------------------------------------

`Group' function accelerate_none(`Problem' S, `Group' y, `FunctionPointer' T) {
	`Integer'	iter
	`Group'		resid
	pragma unset resid

	for (iter=1; iter<=S.maxiterations; iter++) {
		(*T)(S, y, resid) // Faster version of "resid = S.T(y)"
		if (check_convergence(S, iter, resid, y)) break
		y = resid
	}
	return(resid)
}
// -------------------------------------------------------------------------------------------------

// Start w/out acceleration, then switch to CG
`Group' function accelerate_hybrid(`Problem' S, `Group' y, `FunctionPointer' T) {
	`Integer' iter, accel_start
	`Group' resid
	pragma unset resid

	accel_start = 3

	for (iter=1; iter<=accel_start; iter++) {
		(*T)(S, y, resid) // Faster version of "resid = S.T(y)"
		if (check_convergence(S, iter, resid, y)) break
		y = resid
	}

	return(accelerate_cg(S, y, T))
}

// -------------------------------------------------------------------------------------------------
// Memory cost is approx = 4*size(y) (actually 3 since y is already there)
// But we need to add maybe 1 more due to u:*v
// And I also need to check how much does project and T use..
// Double check with a call to memory

// For discussion on the stopping criteria, see the following presentation:
// Arioli & Gratton, "Least-squares problems, normal equations, and stopping criteria for the conjugate gradient method". URL: https://www.stfc.ac.uk/SCD/resources/talks/Arioli-NAday2008.pdf

// Basically, we will use the Hestenes and Stiefel rule

`Group' function accelerate_cg(`Problem' S, `Group' y, `FunctionPointer' T) {
	// BUGBUG iterate the first 6? without acceleration??
	`Integer'	iter, d, Q
	`Group'		r, u, v
	real rowvector alpha, beta, ssr, ssr_old, improvement_potential
	`Matrix' recent_ssr
	pragma unset r
	pragma unset v

	Q = cols(y)
	
	d = 2 // BUGBUG Set it to 2/3 // Number of recent SSR values to use for convergence criteria (lower=faster & riskier)
	// A discussion on the stopping criteria used is described in
	// http://scicomp.stackexchange.com/questions/582/stopping-criteria-for-iterative-linear-solvers-applied-to-nearly-singular-system/585#585

	improvement_potential = weighted_quadcolsum(S, y, y)
	recent_ssr = J(d, Q, .)
	
	(*T)(S, y, r, 1)
	ssr = weighted_quadcolsum(S, r, r) // cross(r,r) when cols(y)==1 // BUGBUG maybe diag(quadcross()) is faster?
	u = r

	for (iter=1; iter<=S.maxiterations; iter++) {
		(*T)(S, u, v, 1) // This is the hottest loop in the entire program
		alpha = safe_divide( ssr , weighted_quadcolsum(S, u, v) )
		recent_ssr[1 + mod(iter-1, d), .] = alpha :* ssr
		improvement_potential = improvement_potential - alpha :* ssr
		y = y - alpha :* u
		r = r - alpha :* v
		ssr_old = ssr
		ssr = weighted_quadcolsum(S, r, r)
		beta = safe_divide( ssr , ssr_old) // Fletcher-Reeves formula, but it shouldn't matter in our problem
		u = r + beta :* u
		// Convergence if sum(recent_ssr) > tol^2 * improvement_potential
		if ( check_convergence(S, iter, colsum(recent_ssr), improvement_potential, "hestenes") ) break
	}
	return(y)
}

// -------------------------------------------------------------------------------------------------

`Group' function accelerate_sd(`Problem' S, `Group' y, `FunctionPointer' T) {
	`Integer'	iter, g
	`Group' proj
	real rowvector t
	pragma unset proj

	for (iter=1; iter<=S.maxiterations; iter++) {
		(*T)(S, y, proj, 1)
		if (check_convergence(S, iter, y-proj, y)) break
		t = safe_divide( weighted_quadcolsum(S, y, proj) , weighted_quadcolsum(S, proj, proj) )
		if (uniform(1,1)<0.1) t = 1 // BUGBUG: Does this help to randomly unstuck an iteration?
		y = y - t :* proj
		
		if (S.storing_betas) {
			for (g=1; g<=S.G; g++) {
				if (length(S.fes[g].target)>0) {
					S.fes[g].alphas = S.fes[g].alphas + t :* S.fes[g].tmp_alphas
				}
			}
		}
	}
	return(y-proj)
}

// -------------------------------------------------------------------------------------------------
// This is method 3 of Macleod (1986), a vector generalization of the Aitken-Steffensen method
// Also: "when numerically computing the sequence.. stop..  when rounding errors become too 
// important in the denominator, where the ^2 operation may cancel too many significant digits"
// Note: Sometimes the iteration gets "stuck"; can we unstuck it with adding randomness
// in the accelerate decision? There should be a better way.. (maybe symmetric kacz instead of standard one?)

`Group' function accelerate_aitken(`Problem' S, `Group' y, `FunctionPointer' T) {
	`Integer'	iter
	`Group'		resid, y_old, delta_sq
	`Boolean'	accelerate
	real rowvector t
	pragma unset resid

	//S.pause_length = 20
	//S.bad_loop_threshold = 1
	//S.stuck_threshold = 5e-3
	// old_error = oldest_error = bad_loop = acceleration_countdown = 0

	y_old = J(rows(y), cols(y), .)

	for (iter=1; iter<=S.maxiterations; iter++) {
		
		(*T)(S, y, resid)
		accelerate = iter>=S.accel_start & !mod(iter,S.accel_freq)

		// Accelerate
		if (accelerate) {
			delta_sq = resid - 2 * y + y_old // = (resid - y) - (y - y_old) // Equivalent to D2.resid
			// t is just (d'd2) / (d2'd2)
			t = safe_divide( weighted_quadcolsum(S,  (resid - y) , delta_sq) ,  weighted_quadcolsum(S, delta_sq , delta_sq) )
			resid = resid - t :*  (resid - y)
		}

		// Only check converge on non-accelerated iterations
		// BUGBUG: Do we need to disable the check when accelerating?
		// if (check_convergence(S, iter, accelerate? resid :* .  : resid, y)) break
		if (check_convergence(S, iter, resid, y)) break
		
		// Experimental: Pause acceleration
		//if (accelerate) {
		//	improvement = max(( (old_error-update_error)/update_error , (oldest_error-update_error)/update_error ))
		//	bad_loop = improvement < stuck_threshold ? bad_loop+1 : 0
		//	// bad_loop, improvement, update_error, old_error, oldest_error
		//	// Tolerate two problems (i.e. 6+2=8 iters) and then try to unstuck
		//	if (bad_loop>bad_loop_threshold) {
		//		bad_loop = 0
		//		if (VERBOSE==3) printf(" Fixed point iteration seems stuck, acceleration paused\n")
		//		acceleration_countdown = pause_length
		//	}
		//	assert(bad_loop<=3)	
		//	oldest_error = old_error
		//	old_error = update_error
		//}
		//
		y_old = y // y_old is resid[iter-2]
		y = resid // y is resid[iter-1]
	}
	return(resid)
}

// -------------------------------------------------------------------------------------------------

`Boolean' check_convergence(`Problem' S, `Integer' iter, `Group' y_new, `Group' y_old,| `String' method) {
	`Boolean'	done, is_last_iter
	`Real'		update_error

	// max() ensures that the result when bunching vars is at least as good as when not bunching
	if (args()<5) method = "vectors" 

	if (S.G==1 & !S.storing_betas) {
		// Shortcut for trivial case (1 FE)
		update_error = 0
	}
	else if (method=="vectors") {
		update_error = max(mean(reldif(y_new, y_old)))
	}
	else if (method=="hestenes") {
		// If the regressor is perfectly explained by the absvars, we can have SSR very close to zero but negative
		// (so sqrt is missing)
		update_error = max(safe_divide( sqrt(y_new) , editmissing(sqrt(y_old), sqrt(epsilon(1)) ) , sqrt(epsilon(1)) ))
	}
	else {
		exit(error(100))
	}

	done = update_error <= S.tolerance
	is_last_iter = iter==S.maxiterations
	
	if (done) {
		S.num_iters_last_run = iter
		if (S.verbose==1) printf("{txt} converged in %g iterations last error =%3.1e)\n", iter, update_error)
		if (S.verbose>1) printf("\n{txt} - Converged in %g iterations (last error =%3.1e)\n", iter, update_error)
	}
	else if (is_last_iter) {
		printf("\n{err}convergence not achieved in %g iterations (last error=%e); try increasing maxiter() or decreasing tol().\n", S.maxiterations, update_error)
		exit(430)
	}
	else {
		if ((S.verbose>=2 & S.verbose<=3 & mod(iter,1)==0) | (S.verbose==1 & mod(iter,10)==0)) {
			printf("{txt}.")
			displayflush()
		}
		if ( (S.verbose>=2 & S.verbose<=3 & mod(iter,100)==0) | (S.verbose==1 & mod(iter,1000)==0) ) printf("{txt}%9.1f\n", update_error/S.tolerance)

		if (S.verbose==4 & method!="hestenes") printf("{txt} iter={res}%4.0f{txt}\tupdate_error={res}%-9.6e\n", iter, update_error)
		if (S.verbose==4 & method=="hestenes") printf("{txt} iter={res}%4.0f{txt}\tupdate_error={res}%-9.6e  {txt}norm(ssr)={res}%g\n", iter, update_error, norm(y_new))
		
		if (S.verbose==5) {
			printf("\n{txt} iter={res}%4.0f{txt}\tupdate_error={res}%-9.6e{txt}\tmethod={res}%s\n", iter, update_error, method)
			"old:"
			y_old
			"new:"
			y_new
		}
	}
	return(done)
}

// -------------------------------------------------------------------------------------------------

`Matrix' weighted_quadcolsum(`Problem' S, `Matrix' x, `Matrix' y) {
	// BUGBUG: colsum or quadcolsum??
		return( quadcolsum(S.weightvar=="" ? (x :* y) : (x :* y :* S.w) ) )
}
	
// -------------------------------------------------------------------------------------------------
// Transformations: Compute RESIDUALS, not projections
// -------------------------------------------------------------------------------------------------

void function transform_cimmino(`Problem' S, `Group' y, `Group' ans,| `Boolean' get_proj) {
	`Integer' 	g, G
	G = S.G
	if (args()<4) get_proj = 0

	ans = map_projection(S, 1, y)
	for (g=2; g<=G; g++) {
		ans = ans + map_projection(S, g, y)
	}
	ans = get_proj ? ans / G : y - ans / G
}

// -------------------------------------------------------------------------------------------------

void function transform_kaczmarz(`Problem' S, `Group' y, `Group' ans,| `Boolean' get_proj) {
	`Integer' 	g, G
	G = S.G
	if (args()<4) get_proj = 0

	ans = y - map_projection(S, 1, y)
	for (g=2; g<=G; g++) {
		ans = ans - map_projection(S, g, ans)
	}
	if (get_proj) ans = y - ans
}

// -------------------------------------------------------------------------------------------------
// This seems slower than kaczmarz (sym kaczmarz!); not used currently
void function transform_rand_kaczmarz(`Problem' S, `Group' y, `Group' ans,| `Boolean' get_proj) {
	`Integer' 	g, G
	G = S.G
	`Vector' rand
	if (args()<4) get_proj = 0
	rand = sort( ( (1::G) , uniform(G,1) ) , 2 )[.,1]

	ans = y - map_projection(S, rand[1], y)
	for (g=2; g<=G; g++) {
		ans = ans - map_projection(S, rand[g], ans)
	}
	for (g=G-1; g>=1; g--) {
		ans = ans - map_projection(S, rand[g], ans)
	}
	if (get_proj) ans = y - ans
}

// -------------------------------------------------------------------------------------------------

 void function transform_sym_kaczmarz(`Problem' S, `Group' y, `Group' ans,| `Boolean' get_proj) {
	`Integer' 	g, G
	// BUGBUG: Streamline and remove all those "ans - .." lines?
	G = S.G
	if (args()<4) get_proj = 0

	ans = y - map_projection(S, 1, y)
	for (g=2; g<=G; g++) {
		ans = ans - map_projection(S, g, ans)
	}
	for (g=G-1; g>=1; g--) {
		ans = ans - map_projection(S, g, ans)
	}
	if (get_proj) ans = y - ans
}
	
void map_estimate_dof(`Problem' S, string rowvector adjustments, 
		| `Varname' groupvar, `String' cond) {
	`Boolean' adj_firstpairs, adj_pairwise, adj_clusters, adj_continuous, belongs, already_first_constant
	string rowvector all_adjustments
	`String' adj, label, basestring
	`Integer' i, g, SuperG, h, M_due_to_nested, j, m, sum_levels
	`Vector' M, M_is_exact, M_is_nested, is_slope, solved, prev_g, SubGs

	// TODO - BY
	// With by, I need to i) discard the first FE, ii) use only the `cond' sample in the calculations

	// Parse list of adjustments/tricks to do
	if (S.verbose>1) printf("\n")
	if (S.verbose>0) printf("{txt}{bf:mata: map_estimate_dof()}\n")
	if (S.verbose>1) printf("{txt} - Estimating degrees-of-freedom used by the fixed effects\n")
	all_adjustments = "firstpairs", "pairwise", "clusters", "continuous"
	adjustments = tokens(adjustments)
	for (i=1; i<=length(adjustments);i++) {
		assert_msg(anyof(all_adjustments, adjustments[i]), 
			sprintf("map_estimate_dof error: adjustment %s invalid", adjustments[i]))
	}
	if (S.verbose>1) printf("{txt} - Adjustments:\n")
	for (i=1;i<=length(all_adjustments);i++) {
		adj = all_adjustments[i]
		belongs = anyof(adjustments, adj)
		if (S.verbose>1) printf("{txt}    - %s:  {col 20}{res} %s\n", adj, belongs ? "yes" : "no")
		if (adj=="firstpairs") adj_firstpairs = belongs
		if (adj=="pairwise") adj_pairwise = belongs
		if (adj=="clusters") adj_clusters = belongs
		if (adj=="continuous") adj_continuous = belongs
	}

	// Assert that the clustervars exist
	for (i=1;i<=S.C;i++) {
		stata(sprintf("confirm numeric variable %s, exact", S.clustervars[i]))
	}

	// Can only save connected group if firstpairs or pairwise are active
	if (args()<3) groupvar = ""
	if (groupvar!="") {
		assert_msg(adj_firstpairs | adj_pairwise, "map_estimate_dof error: group option requires 'pairwise' or 'firstpairs' adjustments")
	}

	// Count all fixed intercepts and slopes
	SubGs = J(S.G, 1, 0) // Intercept + # of slopes in an absvar
	for (g=1;g<=S.G;g++) {
		SubGs[g] = S.fes[g].has_intercept + S.fes[g].num_slopes
	}
	SuperG = sum(SubGs)
	if (S.verbose>1) printf("{txt} - There are %f fixed intercepts and slopes in the %f absvars\n", SuperG, S.G)

	// Initialize result vectors and scalars
	M = J(SuperG, 1, 1)
	M_is_exact = J(SuperG, 1, 0)
	M_is_nested = J(SuperG, 1, 0)
	is_slope = J(SuperG, 1, .)
	solved = J(SuperG, 1, 0)

	// Initial Fill
	h = 0
	already_first_constant = 0
	for (g=1;g<=S.G;g++) {
		for (i=1;i<=SubGs[g];i++) {
			h++
			if (is_slope[h] = i>S.fes[g].has_intercept) {
				M[h] = 0
			}
			else if (!already_first_constant) {
				already_first_constant = 1
				M[h] = 0
			}

		}
	}

	// (Intercept-Only) Look for absvars that are clustervars or are nested within a clustervar
	h = 1
	M_due_to_nested = 0
	if (adj_clusters) {
		for (g=1;g<=S.G;g++) {
			if (S.fes[g].has_intercept & (S.fes[g].is_clustervar | S.fes[g].in_clustervar)) {
				M[h] = S.fes[g].levels
				M_is_exact[h] = M_is_nested[h] = 1
				M_due_to_nested = M_due_to_nested + M[h]
				solved[h] = 1
				if (S.verbose>1 & S.fes[g].is_clustervar) printf("   {txt}(categorical variable {res}%s{txt} is also a cluster variable, so it doesn't count towards DoF)\n", invtokens(S.fes[g].ivars,"#"))
				if (S.verbose>1 & S.fes[g].in_clustervar) printf("   {txt}(categorical variable {res}%s{txt} is nested within cluster {res}%s{txt}, so it doesn't count towards DoF)\n", invtokens(S.fes[g].ivars,"#"), S.clustervars_original[S.fes[g].nesting_clustervar])
			}
			h = h + SubGs[g]
		}
	}

	// (Intercept-only) Excluding those already solved, the first absvar is exact, and the second can be with pairwise/firstpairs

	// Note: I dont't include the FEs that are clusters or are nested within cluster when computing redundant coefs
	// On principle, that would be nice to have. EG: reghdfe .... abs(zipcode state##c.time) vce(zipcode)
	// I know state is collinear with zipcode so I would also want to consider state to be redundant

	// However, the number of states should be much smaller than the number of zipcodes, which in turn is smaller
	// Than the number of observations; so I don't worry much about that case (also, there may be possible 
	// complications with that)

	i = 0
	h = 1
	prev_g = J(S.G, 1, 0)
	for (g=1;g<=S.G;g++) {
		if (!solved[h] & S.fes[g].has_intercept) {
			i++
			if (i==1) {
				M_is_exact[h] = 1
			}
			else if (i==2 & (adj_pairwise | adj_firstpairs)) {
				M_is_exact[h] = 1
				m = map_connected_groups(S, prev_g[1], g, groupvar)
				if (S.verbose>2) printf("{txt}    - Mobility groups between fixed intercept #%f and #%f: {res}%f\n", prev_g[1], g, m)
				M[h] = m
			}
			else if (i>2 & adj_pairwise) {
				// Call connected in a LOOP (but I need to save the list of those that I needed to check)
				for (j=1; j<i; j++) {
					m = map_connected_groups(S, prev_g[j], g)
					if (S.verbose>2) printf("{txt}    - Mobility groups between fixed intercept #%f and #%f: {res}%f\n", prev_g[j], g, m)
					M[h] = max((M[h], m))
				}
				if (S.verbose>2) printf("{txt}    - Maximum of mobility groups wrt fixed intercept #%f: {res}%f\n", g, M[h])

			}
			prev_g[i] = g
		}
		h = h + SubGs[g]
	}

	// See if cvars are zero (w/out intercept) or just constant (w/intercept)
	if (adj_continuous) {
		h = 0
		for (g=1;g<=S.G;g++) {
			for (i=1;i<=SubGs[g];i++) {
				h++
				// If model has intercept, redundant cvars are those that are CONSTANT
				// Without intercept, a cvar has to be zero within a FE for it to be redundant
				// Since S.fes[g].x are already demeaned IF they have intercept, we don't have to worry about the two cases
				if (is_slope[h]) {
					M[h] = count_redundant_cvars(S, g, i)
				}
			}
		}
	}

	// Store results
	S.dof_SubGs = SubGs
	
	S.doflist_M = M
	S.doflist_M_is_exact = M_is_exact
	S.doflist_M_is_nested = M_is_nested

	sum_levels = 0
	for (g=1;g<=S.G;g++) sum_levels = sum_levels + S.fes[g].levels * (S.fes[g].has_intercept + S.fes[g].num_slopes)
	S.dof_M = sum(M)
	S.dof_KminusM = sum_levels - S.dof_M
	S.dof_M_due_to_nested = M_due_to_nested
	S.dof_N_hdfe_extended = SuperG

	st_numscalar("e(df_a)", S.dof_KminusM) // We need this in the regression stage!

	// Report results
	if (S.verbose>=2) {
		printf("{txt} - Degrees-of-freedom used by each fixed effect (K=total levels; M=redundant levels)\n")
		h = 0
		for (g=1;g<=S.G;g++) {
			for (i=1;i<=SubGs[g];i++) {
				h++
				label = invtokens(S.fes[g].ivars, "#")
				if (i>S.fes[g].has_intercept) label = label + "#c." + S.fes[g].cvars[i-S.fes[g].has_intercept]
				basestring = "{txt}   - FE%f ({res}%s{txt}): {col 40}K=%f {col 50}M=%f {col 60}is_exact=%f\n"
				printf(basestring, g, label, S.fes[g].levels, M[h], M_is_exact[h])
			}
		}
	}
	if (S.verbose>0) printf(" - Results: N=%f ; K=%f ; M=%f ; (K-M)==df_a=%f\n", S.N, sum_levels, sum(M), sum_levels-sum(M))
}
// -------------------------------------------------------------------------------------------------

void function map_ereturn_dof(`Problem' S) {
	`Integer' h, g, i

	st_numscalar("e(N_hdfe)", S.G)
	st_numscalar("e(N_hdfe_extended)", S.dof_N_hdfe_extended)
	st_numscalar("e(mobility)", S.dof_M)
	st_numscalar("e(M_due_to_nested)", S.dof_M_due_to_nested)
	st_numscalar("e(df_a)", S.dof_KminusM)

	h = 0
	for (g=1;g<=S.G;g++) {
		for (i=1;i<=S.dof_SubGs[g];i++) {
			h++
			st_numscalar( sprintf("e(M%f)",h) , S.doflist_M[h] )
			st_numscalar( sprintf("e(K%f)",h) , S.fes[g].levels )

			st_numscalar( sprintf("e(M%f_exact)",h) , S.doflist_M_is_exact[h])
			st_numscalar( sprintf("e(M%f_nested)",h) , S.doflist_M_is_nested[h])
			st_numscalar( sprintf("e(G%f)",h) , g) // unused?
		}
	}
}

// -------------------------------------------------------------------------------------------------

`Integer' function count_redundant_cvars(`Problem' S, `Integer' g, `Integer' i) {
	`Integer' j, i_lower, i_upper, ans, L, ii
	real rowvector min_max
	`Series' x

	ii = i-S.fes[g].has_intercept
	ans = 0
	L = S.fes[g].levels
	x = S.fes[g].x[., ii]
	
	i_lower = 1
	for (j=1;j<=L; j++) {
		i_upper = S.fes[g].offsets[j]
		min_max = minmax(x[| i_lower \ i_upper |])
		if (sqrt(epsilon(1))>abs(min_max[1]) & sqrt(epsilon(1))>abs(min_max[2])) ans++
		i_lower = i_upper + 1
	}
	if (S.verbose>=2) printf("{txt}    - Fixed slope {res}%s#c.%s {txt}has {res}%f/%f{txt} redundant coefs.\n", invtokens(S.fes[g].ivars,"#"), S.fes[g].cvars[ii], ans, L)
	return(ans)
}

/*
	In general, we can't know the exact number of DoF lost because we don't know when multiple FEs are collinear
	When we have two pure FEs, we can use an existing algorithm, but besides that we'll just use an upper (conservative) bound

	Features:
	 - Save the first mobility group if asked
	 - Within the pure FEs, we can use the existing algorithm pairwise (FE1 vs FE2, FE3, .., FE2 vs FE3, ..)
	 - If there are n pure FEs, that means the algo gets called n! times, which may be kinda slow
	 - With FEs interacted with continuous variables, we can't do this, but can do two things:
		a) With i.a#c.b , whenever b==0 for all values of a group (of -a-), add one redundant
		b) With i.a##c.b, do the same but whenever b==CONSTANT (so not just zero)
     - With clusters, it gets trickier but in summary you don't need to penalize DoF for params that only exist within a cluster. This happens:
		a) if absvar==clustervar
		b) if absvar is nested within a clustervar. EG: if we do vce(cluster state), and -absorb(district)- or -absorb(state#year)
		c) With cont. interactions, e.g. absorb(i.state##c.year) vce(cluster year), then i) state FE is redundant, but ii) also state#c.year
		   The reason is that at the param for each "fixed slope" is shared only within a state

	Procedure:
	 - Go through all FEs and see if i) they share the same ivars as any clusters, and if not, ii) if they are nested within clusters
	 - For each pure FE in the list, run the algorithm pairwise, BUT DO NOT RUN IT BEETWEEN TWO PAIRS OF redundant
	   (since the redundants are on the left, we just need to check the rightmost FE for whether it was tagged)
	 - For the ones with cont interactions, do either of the two tests depending on the case

	Misc:
	 - There are two places where DoFs enter in the results:
		a) When computing e(V), we do a small sample adjustment (seen in Stata documentation as the -q-)
		   Instead of doing V*q with q = N/(N-k), we use q = N / (N-k-kk), so THE PURPOSE OF THIS PROGRAM IS TO COMPUTE "kk"
		   This kk will be used to adjust V and also stored in e(df_a)
		   With clusters, q = (N-1) / (N-k-kk) * M / (M-1)
		   With multiway clustering, we use the smallest N_clust as our M
	    b) In the DoF of the F and t tests (not when doing chi/normal)
	       When there are clusters, note that e(df_r) is M-1 instead of N-1-k
	       Again, here we want to use the smallest M with multiway clustering

	Inputs: +-+- if we just use -fe2local- we can avoid passing stuff around when building subroutines
	 - We need the current name of the absvars and clustervars (remember a#b is replaced by something different)
	 - Do a conf var at this point to be SURE that we didn't mess up before
	 - We need the ivars and cvars in a list
	 - For the c. interactions, we need to know if they are bivariate or univariate
	 - SOLN -> mata: fe2local(`g')  ; from mata: ivars_clustervar`i' (needed???) , and G
	 - Thus, do we really needed the syntax part??
	 - fe2local saves: ivars cvars target varname varlabel is_interaction is_cont_interaction is_bivariate is_mock levels // Z group_k weightvar

	DOF Syntax:
	 DOFadjustments(none | all | CLUSTERs | PAIRwise | FIRSTpair | CONTinuous)
	 dof() = dof(all) = dof(cluster pairwise continuous)
	 dof(none) -> do nothing; all Ms = 0 
	 dof(first) dof(first cluster) dof(cluster) dof(continuous)

	For this to work, the program MUST be modular
*/
	
`Integer' function map_connected_groups(`Problem' S, `Integer' g1, `Integer' g2, | `Varname' groupvar) {
	`Boolean' changed
	`Series' group, p
	`Integer' gg, g, j, i_lower, i_upper, num_groups, L
	real rowvector min_max

	changed = 1
	group = st_data(., S.fes[g1].idvarname)
	if (args()<4) groupvar = ""
	
	while (changed) {
		changed = 0
		for (gg=1;gg<=2;gg++) {
			g = gg==1 ? g2 : g1
			L = S.fes[g].levels
			if (!S.fes[g].is_sortedby) _collate(group, S.fes[g].p) // Sort it by g1 or g2
			i_lower = 1
			for (j=1;j<=L; j++) {
				i_upper = S.fes[g].offsets[j]
				min_max = minmax(group[| i_lower , 1 \ i_upper , 1 |])
				if (min_max[1]!=min_max[2]) changed = 1
				group[| i_lower , 1 \ i_upper , 1 |] = min_max[1] :* J(i_upper-i_lower+1,1,1)
				i_lower = i_upper + 1
			}
			if (!S.fes[g].is_sortedby) _collate(group, S.fes[g].inv_p) // Sort it back
		}
	}

	// Create compact group id
	p = order(group, 1)
	_collate(group, p)
	group = runningsum(rows_that_change(group))
	num_groups = group[rows(group)]
	_collate(group, invorder(p))
	
	// (optional) save group variable
	// Don't save until back in the main dataset!
	// S.groupvar = groupvar // already saved in map_init_groupvar
	S.grouptype = num_groups<=100 ? "byte" : (num_groups<=32740? "int" : "long")
	S.grouplabel = sprintf("Mobility Group: %s <--> %s", invtokens(S.fes[g1].ivars,"#") , invtokens(S.fes[g2].ivars,"#"))
	S.groupseries = group
	return(num_groups)
}

	// This is not part of the MAP code but for simplicity we'll put it here
	
// -------------------------------------------------------------------------------------------------
// Fix nonpositive VCV; called from Wrapper_mwc.ado 
// -------------------------------------------------------------------------------------------------
void function fix_psd(string scalar Vname) {
	real matrix V, U, lambda

	V = st_matrix(Vname)
	if (!issymmetric(V)) exit(error(505))
	symeigensystem(V, U=., lambda=.)
	st_local("eigenfix", "0")
	if (min(lambda)<0) {
		lambda = lambda :* (lambda :>= 0)
		// V = U * diag(lambda) * U'
		V = quadcross(U', lambda, U')
		st_local("eigenfix", "1")
	}
	st_replacematrix(Vname, V)
}

end
// -------------------------------------------------------------------------------------------------

program define hdfe, eclass
* Note: based on 

* Set Stata version
	version `=clip(`c(version)', 11.2, 13.1)' // 11.2 minimum, 13+ preferred

* Intercept version
	cap syntax, version
	if !c(rc) {
		Version
		exit
	}

* Parse options specific to hdfe.ado: partial sample generate clear clustervars
	syntax anything(everything) [fw aw pw/], [*] ///
		[CACHE(string) VCE(string) CLUSTER(string) FAST] /// Disabled options
		Absorb(string) [ ///
		/// PARTIAL(varlist numeric) /// Additional regressors besides those in absorb()
		CLUSTERVars(string) /// Used to estimate the DoF
		Generate(name) SAMPLE(name) ///
		CLEAR KEEPIDs KEEPVars(varlist) ///
		 ///
		]

	Assert "`cache'"=="", msg("invalid option {cmd:cache()}")
	Assert "`vce'"=="", msg("invalid option {cmd:vce()}")
	Assert "`fast'"=="", msg("invalid option {cmd:fast()}")
	Assert "`cluster'"=="", msg("invalid option {cmd:cluster()}, perhaps you meant {opt clusterv:ars()}?")
	Assert ("`generate'"!="") + ("`clear'"!="") == 1 , ///
		msg("hdfe error: you need to specify one and only one of the following options: clear generate(...)")

	if ("`clear'"!="") Assert "`sample'"=="", msg("option {cmd:sample()} not compatible with {cmd:clear}")
	if ("`generate'"!="") Assert "`keepids'"=="", msg("option {cmd:keepids} not compatible with {cmd:generate()}")
	if ("`generate'"!="") Assert "`keepvars'"=="", msg("option {cmd:keepvars()} not compatible with {cmd:generate()}")

	cap drop __ID*__
	cap drop __CL*__
	
	if ("`keepvars'"!="") {
		qui ds `keepvars'
		local keepvars `r(varlist)'
	}

	if ("`weight'"!="") local weight_part [`weight'=`exp']
	local 0 `partial' `anything' `weight_part' , absorb(`absorb') `options' ///
		cluster(`clustervars') cache(save, keepvars(`keepvars'))

* INITIAL CLEANUP
	ereturn clear // Clear previous results and drops e(sample)

* From now on, we will pollute the Mata workspace, so wrap this in case of error
	cap noi {

* PARSE - inject opts with c_local, create Mata structure HDFE_S (use verbose>2 for details)
	Parse `0'
	assert `savecache'
	Assert !`will_save_fe', msg("savecache disallows saving FEs")

	if ("`clear'"=="") {
		preserve
		tempvar uid
		GenUID `uid'
	}

* PROBLEM:
	* I can translate L(1/2).x into __L__x __L2__x
	* But how can I translate i.x if I don't have the original anymore?

* SOLUTION
	* The cache option of ExpandFactorVariables (called from Compact.ado)

* COMPACT - Expand time and factor variables, and drop unused variables and obs.
	Compact, basevars(`basevars') depvar(`depvar' `indepvars') uid(`uid') timevar(`timevar') panelvar(`panelvar') weightvar(`weightvar') weighttype(`weighttype') ///
		absorb_keepvars(`absorb_keepvars') clustervars(`clustervars') ///
		if(`if') in(`in') verbose(`verbose') vceextra(`vceextra') savecache(1) more_keepvars(`keepvars')
	// Injects locals: depvar indepvars endogvars instruments expandedvars cachevars

* PRECOMPUTE MATA OBJECTS (means, counts, etc.)
	mata: map_init_keepvars(HDFE_S, "`expandedvars' `uid' `cachevars' `keepvars'") 	// Non-essential vars will be deleted (e.g. interactions of a clustervar)
	mata: map_precompute(HDFE_S)
	global updated_clustervars = "`r(updated_clustervars)'"

* Store UID in Mata so we can then attach the variables without an expensive merge
	if ("`clear'"=="") mata: store_uid(HDFE_S, "`uid'")
	
* COMPUTE DOF
	if (`timeit') Tic, n(62)
	mata: map_estimate_dof(HDFE_S, "`dofadjustments'", "`groupvar'") // requires the IDs
	if (`timeit') Toc, n(62) msg(estimate dof)
	assert e(df_a)<. // estimate_dof() only sets e(df_a); map_ereturn_dof() is for setting everything aferwards
	local kk = e(df_a) // we need this for the regression step

* MAP_SOLVE() - WITHIN TRANFORMATION (note: overwrites variables)
	qui ds `expandedvars'
	local NUM_VARS : word count `r(varlist)'
	Debug, msg("(computing residuals for `NUM_VARS' variables)")
	
* Build newvar string (trick: if generate is empty, then newvars==expandedvars)
	foreach var of local expandedvars {
		local newvars `newvars' `generate'`var'
	}

	local restore_dta = ("`clear'"=="")
	mata: map_solve(HDFE_S, "`expandedvars'", "`newvars'", `restore_dta')

	foreach var of local expandedvars {
		local label : char `generate'`var'[name]
		if ("`label'"=="") local label `var'
		la var `generate'`var' "Residuals: `label'"
	}

	if ("`groupvar'"!="") mata: groupvar2dta(HDFE_S, `restore_dta')

	if ("`sample'"!="") {
		mata: esample2dta(HDFE_S, "`sample'")
		qui replace `sample' = 0 if `sample'==.
		la var `sample' "[HDFE Sample]"
		mata: drop_uid(HDFE_S)
	}

* Absorbed-specific returns
	* e(N_hdfe) e(N_hdfe_extended) e(mobility)==M e(df_a)==K-M
	* e(M#) e(K#) e(M#_exact) e(M#_nested) -> for #=1/e(N_hdfe_extended)
	mata: map_ereturn_dof(HDFE_S)
	local N_hdfe = e(N_hdfe)
	ereturn local cmd = "hdfe"
	ereturn local extended_absvars "`extended_absvars'"
	ereturn local absvars "`original_absvars'"

* Cleanup
	} // cap noi
	local rc = c(rc)
	cap mata: mata drop HDFE_S // overwrites c(rc)
	*cap mata: mata drop varlist_cache
	cap global updated_clustervars

	local keys absorb N_hdfe original_absvars extended_absvars vce vceoption vcetype ///
		vcesuite vceextra num_clusters clustervars bw kernel dkraay kiefer twicerobust ///
		reghdfe_cache // cache_obs
	foreach key of local keys {
		char _dta[`key']
	}

	if ("`keepids'"=="" | `rc') cap drop __ID*__
	if ("`keepids'"=="" | `rc') cap drop __CL*__

	if (`rc') exit `rc'
end

// -------------------------------------------------------------------------------------------------

// -------------------------------------------------------------
// Simple assertions
// -------------------------------------------------------------

program define Assert
    syntax anything(everything equalok) [, MSG(string asis) RC(integer 198)]
    if !(`anything') {
        di as error `msg'
        exit `rc'
    }
end


// -------------------------------------------------------------
// Simple debugging
// -------------------------------------------------------------

program define Debug

	syntax, [MSG(string asis) Level(integer 1) NEWline COLOR(string)] [tic(integer 0) toc(integer 0)]
	
	mata: verbose2local(HDFE_S, "VERBOSE")
	assert "`VERBOSE'"!=""
	assert inrange(`VERBOSE',0, 5)
	
	assert inrange(`level',0, 5)
	assert (`tic'>0) + (`toc'>0)<=1

	if ("`color'"=="") local color text
	assert inlist("`color'", "text", "res", "result", "error", "input")

	if (`VERBOSE'>=`level') {

		if (`tic'>0) {
			timer clear `tic'
			timer on `tic'
		}
		if (`toc'>0) {
			timer off `toc'
			qui timer list `toc'
			local time = r(t`toc')
			if (`time'<10) local time = string(`time'*1000, "%tcss.ss!s")
			else if (`time'<60) local time = string(`time'*1000, "%tcss!s")
			else if (`time'<3600) local time = string(`time'*1000, "%tc+mm!m! SS!s")
			else if (`time'<24*3600) local time = string(`time'*1000, "%tc+hH!h! mm!m! SS!s")
			timer clear `toc'
			local time `" as result " `time'""'
		}

		if (`"`msg'"'!="") di as `color' `msg'`time'
		if ("`newline'"!="") di
	}
end


// -------------------------------------------------------------
// Report HDFE/REGHDFE version
// -------------------------------------------------------------

program define Version, eclass
    local version "3.2.9 21feb2016"
    ereturn clear
    di as text "`version'"
    ereturn local version "`version'"

    di as text _n "Dependencies installed?"
    local dependencies ivreg2 avar tuples
    foreach dependency of local dependencies {
    	cap findfile `dependency'.ado
    	if (_rc) {
    		di as text "{lalign 20:- `dependency'}" as error "not"
    	}
    	else {
    		di as text "{lalign 20:- `dependency'}" as result "yes"
    	}
    }

end

program define Tic
syntax, n(integer)
	timer clear `n'
	timer on `n'
end

program define Toc
syntax, n(integer) msg(string)
	timer off `n'
	qui timer list `n'
	di as text "[timer]{tab}" as result %8.3f `r(t`n')' as text "{col 20}`msg'{col 77}`n'" 
	timer clear `n'
end

	
// -------------------------------------------------------------
// Parsing and basic sanity checks for REGHDFE.ado
// -------------------------------------------------------------

program define Parse

* Remove extra spacing from cmdline (just for aesthetics)
	mata: st_local("cmdline", stritrim(`"reghdfe `0'"') )

* Parse the broad syntax (also see map_init(), ParseAbsvars.ado, ParseVCE.ado, etc.)
	syntax anything(id="varlist" name=0 equalok) [if] [in] [aw pw fw/] , ///
		/// Model ///
		Absorb(string) [ ///
		RESiduals(name) ///
		SUBOPTions(string) /// Options to be passed to the estimation command (e.g . to regress)
		/// Standard Errors ///
		VCE(string) CLuster(string) /// cluster() is an undocumented alternative to vce(cluster ...)
		/// IV/2SLS/GMM ///
		ESTimator(string) /// 2SLS GMM2s CUE LIML
		STAGEs(string) /// besides iv (always on), first reduced ols acid (and all)
		FFirst /// Save first-stage stats (only with ivreg2)
		IVsuite(string) /// ivreg2 or ivregress
		/// Diagnostic ///
		Verbose(string) ///
		TIMEit ///
		/// Optimization /// Defaults are handled within Mata		
		TOLerance(string) ///
		MAXITerations(string) ///
		POOLsize(string) /// Process variables in batches of #
		ACCELeration(string) ///
		TRAnsform(string) ///
		/// Speedup Tricks ///
		CACHE(string) ///
		FAST ///
		/// Degrees-of-freedom Adjustments ///
		DOFadjustments(string) ///
		GROUPVar(name) /// Variable that will contain the first connected group between FEs
		/// Undocumented ///
		KEEPSINgletons /// (UNDOCUMENTED) Will keep singletons
		NOTES(string) /// NOTES(key=value ...), will be stored on e()
		] [*] // Captures i) display options, ii) SUmmarize|SUmmarize(...)

	local allkeys cmdline if in timeit

* Do this early
	local timeit = "`timeit'"!=""
	local fast = "`fast'"!=""
	local ffirst = "`ffirst'"!=""
	
	if ("`cluster'"!="") {
		Assert ("`vce'"==""), msg("cannot specify both cluster() and vce()")
		local vce cluster `cluster'
		local cluster // Set it to empty to avoid bugs in subsequent lines
	}

* Also early
	ParseCache, cache(`cache') ifin(`if'`in') absorb(`absorb') vce(`vce')
	local keys savecache keepvars usecache
	foreach key of local keys {
		local `key' "`s(`key')'"
	}
	local allkeys `allkeys' `keys'

* Parse varlist: depvar indepvars (endogvars = iv_vars)
	ParseIV `0', estimator(`estimator') ivsuite(`ivsuite')
	local keys subcmd model ivsuite estimator depvar indepvars endogvars instruments fe_format basevars
	foreach key of local keys {
		local `key' "`s(`key')'"
	}
	local allkeys `allkeys' `keys'

* Weights
	if ("`weight'"!="") {
		local weightvar `exp'
		local weighttype `weight'
		local weightexp [`weight'=`weightvar']
		confirm var `weightvar', exact // just allow simple weights

		* Check that weights are correct (e.g. with fweight they need to be integers)
		local num_type = cond("`weight'"=="fweight", "integers", "reals")
		local basenote "{txt}weight {res}`weightvar'{txt} can only contain strictly positive `num_type', but"
		local if_and "if"
		if ("`if'"!="") local if_and "`if' &"
		qui cou `if_and' `weightvar'<0
		Assert (`r(N)'==0), msg("`basenote' `r(N)' negative values were found!")  rc(402)
		qui cou `if_and' `weightvar'==0
		if (`r(N)'>0) di as text "`basenote' `r(N)' zero values were found (will be dropped)"
		qui cou `if_and' `weightvar'>=.
		if (`r(N)'>0) di as text "`basenote' `r(N)' missing values were found (will be dropped)"
		if ("`weight'"=="fweight") {
			qui cou `if_and' mod(`weightvar',1) & `weightvar'<.
			Assert (`r(N)'==0), msg("`basenote' `r(N)' non-integer values were found!" "{err} Stopping execution") rc(401)
		}
	}
	local allkeys `allkeys' weightvar weighttype weightexp

* Parse Absvars and optimization options
if (!`usecache') {
	ParseAbsvars `absorb' // Stores results in r()
		if (inlist("`verbose'", "4", "5")) return list
		local absorb_keepvars `r(all_ivars)' `r(all_cvars)'
		local N_hdfe `r(G)'
		local has_intercept = `r(has_intercept)'
		assert inlist(`has_intercept', 0, 1)

	mata: HDFE_S = map_init() // Reads results from r()
		local will_save_fe = `r(will_save_fe)' // Returned from map_init()
		local original_absvars "`r(original_absvars)'"
		local extended_absvars "`r(extended_absvars)'"
		local equation_d "`r(equation_d)'"
}
else {
	local will_save_fe 0
	local original_absvars : char _dta[original_absvars]
	local extended_absvars : char _dta[extended_absvars]
	local equation_d
	local N_hdfe : char _dta[N_hdfe]
	local has_intercept : char _dta[has_intercept]
}
	local allkeys `allkeys' absorb_keepvars N_hdfe will_save_fe original_absvars extended_absvars equation_d has_intercept

	* Tell Mata what weightvar we have
	if ("`weightvar'"!="" & !`usecache') mata: map_init_weights(HDFE_S, "`weightvar'", "`weighttype'")

	* Time/panel variables (need to give them to Mata)
	local panelvar `_dta[_TSpanel]'
	local timevar `_dta[_TStvar]'
	if ("`panelvar'"!="") {
		cap conf var `panelvar'
		if (c(rc)==111) local panelvar // if the var doesn't exist, set it empty
	}
	if ("`timevar'"!="") {
		cap conf var `timevar'
		if (c(rc)==111) local timevar // if the var doesn't exist, set it empty
	}

	* Parse optimization options (pass them to map_init_*)
	* String options
	local optlist transform acceleration panelvar timevar
	foreach opt of local optlist {
		if ("``opt''"!="" & !`usecache') mata: map_init_`opt'(HDFE_S, "``opt''")
	}
	local allkeys `allkeys' `optlist'

	* This allows changing the groupvar name with -usecache-
	if ("`groupvar'"!="") mata: map_init_groupvar(HDFE_S, "`groupvar'")

	* Numeric options
	local keepsingletons = ("`keepsingletons'"!="")
	local optlist poolsize verbose tolerance maxiterations keepsingletons timeit
	foreach opt of local optlist {
		if ( "``opt''"!="" & (!`usecache' | "`opt'"=="verbose") ) mata: map_init_`opt'(HDFE_S, ``opt'')
	}
	local allkeys `allkeys' `optlist'

	* Return back default value of -verbose-
	mata: verbose2local(HDFE_S, "verbose")
	local allkeys `allkeys' verbose

* Stages (before vce)
	ParseStages, stages(`stages') model(`model')
	local stages "`s(stages)'"
	local stage_suboptions "`s(stage_suboptions)'"
	local savestages = `s(savestages)'
	local allkeys `allkeys' stages stage_suboptions savestages

* Parse VCE options (after stages)
	local keys vceoption vcetype vcesuite vceextra num_clusters clustervars bw kernel dkraay kiefer twicerobust
	if (!`usecache') {
		mata: st_local("hascomma", strofreal(strpos("`vce'", ","))) // is there a commma already in `vce'?
		local vcetmp `vce'
		if (!`hascomma') local vcetmp `vce' ,
		ParseVCE `vcetmp' weighttype(`weighttype') ivsuite(`ivsuite') model(`model')
		foreach key of local keys {
			local `key' "`s(`key')'"
		}
	}
	else {
		foreach key of local keys {
			local `key' : char _dta[`key']
		}
	}

	local allkeys `allkeys' `keys'

* Parse FFIRST (save first stage statistics)
	local allkeys `allkeys' ffirst
	if (`ffirst') Assert "`model'"!="ols", msg("ols does not support {cmd}ffirst")
	if (`ffirst') Assert "`ivsuite'"=="ivreg2", msg("option {cmd}ffirst{err} requires ivreg2")
	
* Update Mata
	if ("`clustervars'"!="" & !`usecache') mata: map_init_clustervars(HDFE_S, "`clustervars'")
	if ("`vceextra'"!="" & !`usecache') mata: map_init_vce_is_hac(HDFE_S, 1)

* DoF Adjustments
	if ("`dofadjustments'"=="") local dofadjustments all
	ParseDOF , `dofadjustments'
	local dofadjustments "`s(dofadjustments)'"
	* Mobility groups
	if ("`groupvar'"!="") conf new var `groupvar'
	local allkeys `allkeys' dofadjustments groupvar

* Parse residuals
	if ("`residuals'"!="") {
		Assert !`will_save_fe', msg("option residuals() is mutually exclusive with saving fixed effects")
		Assert !`savecache', msg("option residuals() is mutually exclusive with -savecache-")
		conf new var `residuals'
		local allkeys `allkeys' residuals
	}

* Parse summarize option: [summarize | summarize( stats... [,QUIetly])]
	* Note: ParseImplicit deals with "implicit" options and fills their default values
	local default_stats mean min max
	ParseImplicit, opt(SUmmarize) default(`default_stats') input(`options') syntax([namelist(name=stats)] , [QUIetly]) inject(stats quietly)
	local summarize_quietly = ("`quietly'"!="")
	if ("`stats'"=="" & "`quietly'"!="") local stats `default_stats'
	local allkeys `allkeys' stats summarize_quietly

* Parse speedups
	if (`fast' & ("`groupvar'"!="" | `will_save_fe'==1 | "`residuals'"!="")) {
		di as error "(warning: option -fast- disabled; not allowed when saving variables: saving fixed effects, mobility groups, residuals)"
		local fast 0
	}
	local allkeys `allkeys' fast level

* Nested
	local nested = cond("`nested'"!="", 1, 0) // 1=Yes
	if (`nested' & !("`model'"=="ols" & "`vcetype'"=="unadjusted") ) {
		di as error "-nested- not implemented currently"
		Debug, level(0) msg("(option nested ignored, only works with OLS and conventional/unadjusted VCE)") color("error")
	}
	local allkeys `allkeys' nested

* Sanity checks on speedups
* With -savecache-, this adds chars (modifies the dta!) so put it close to the end
	if (`savecache') {
		* Savecache "requires" a previous preserve, so we can directly modify the dataset
		Assert "`endogvars'`instruments'"=="", msg("cache(save) option requires a normal varlist, not an iv varlist")
		char _dta[reghdfe_cache] 1
		local chars absorb N_hdfe has_intercept original_absvars extended_absvars vce vceoption vcetype vcesuite vceextra num_clusters clustervars bw kernel dkraay kiefer twicerobust
		foreach char of local  chars {
			char _dta[`char'] ``char''	
		}
	}

* Parse Coef Table Options (do this last!)
	_get_diopts diopts options, `options' // store in `diopts', and the rest back to `options'
	Assert `"`options'"'=="", msg(`"invalid options: `options'"')
	if ("`hascons'`tsscons'"!="") di in ye "(option `hascons'`tsscons' ignored)"
	local allkeys `allkeys' diopts

* Other keys:
	local allkeys `allkeys' suboptions notes
	// Missing keys: check

* Return values
	Debug, level(3) newline
	Debug, level(3) msg("{title:Parsed options:}")
	foreach key of local allkeys {
		if (`"``key''"'!="") Debug, level(3) msg("  `key' = " as result `"``key''"')
		c_local `key' `"``key''"' // Inject values into caller (reghdfe.ado)
	}

end

program define ParseCache, sclass
	syntax, [CACHE(string)] [IFIN(string) ABSORB(string) VCE(string)] 
	if ("`cache'"!="") {
		local 0 `cache'
		syntax name(name=opt id="cache option"), [KEEPvars(varlist)]
		Assert inlist("`opt'", "save", "use"), msg("invalid cache option {cmd`opt'}") // -clear- is also a valid option but intercepted earlier
	}

	local savecache = ("`opt'"=="save")
	local usecache = ("`opt'"=="use")
	local is_cache : char _dta[reghdfe_cache]

	* Sanity checks on usecache
	if (`usecache') {
		local cache_obs : char _dta[cache_obs]
		local cache_absorb : char _dta[absorb]
		local cache_vce : char _dta[vce]

		Assert "`is_cache'"=="1" , msg("cache(use) requires a previous cache(save) operation")
		Assert `cache_obs'==`c(N)', msg("dataset cannot change after cache(save)")
		Assert "`cache_absorb'"=="`absorb'", msg("cached dataset has different absorb()")
		Assert "`ifin'"=="", msg("cannot use if/in with cache(use); data has already been transformed")
		Assert "`cache_vce'"=="`vce'", msg("cached dataset has a different vce()")
	}
	else {
		Assert "`is_cache'"!="1", msg("reghdfe error: data transformed with cache(save) requires cache(use)")
	}
	
	if (!`savecache') Assert "`keepvars'"=="", msg("reghdfe error: {cmd:keepvars()} suboption requires {cmd:cache(save)}")

	local keys savecache keepvars usecache
	foreach key of local keys {
		sreturn local `key' ``key''
	}
end

program define ParseIV, sclass
	syntax anything(id="varlist" name=0 equalok), [ ///
		estimator(string) ivsuite(string) ]

	* Parses varlist: depvar indepvars [(endogvars = instruments)]
		* depvar: dependent variable
		* indepvars: included exogenous regressors
		* endogvars: included endogenous regressors
		* instruments: excluded exogenous regressors

	* Model: OLS or IV-type?
	local model ols
	foreach _ of local 0 {
		if (substr(`"`_'"', 1, 1)=="(") {
			local model iv
			continue, break
		}
	}

	* IV Suite
	if ("`model'"=="iv") {
		if ("`ivsuite'"=="") local ivsuite ivreg2 // Set default
		Assert inlist("`ivsuite'","ivreg2","ivregress") , ///
			msg("error: wrong IV routine (`ivsuite'), valid options are -ivreg2- and -ivregress-")
		cap findfile `ivsuite'.ado
		Assert !_rc , msg("error: -`ivsuite'- not installed, please run {stata ssc install `ivsuite'} or change the option 	-ivsuite-")
		local subcmd `ivsuite'
	}
	else {
		local subcmd regress
	}

	* Estimator
	if ("`estimator'"=="" & "`model'"=="iv") local estimator 2sls // Set default
	if ("`estimator'"!="") {
		Assert "`model'"=="iv", ///
			msg("reghdfe error: estimator() requires an instrumental-variable regression")
		if (substr("`estimator'", 1, 3)=="gmm") local estimator gmm2s
		Assert inlist("`estimator'", "2sls", "gmm2s", "liml", "cue"), ///
			msg("reghdfe error: invalid estimator `estimator'")
		if ("`estimator'"=="cue") Assert "`ivsuite'"=="ivreg2", ///
			msg("reghdfe error: estimator `estimator' only available with the ivreg2 command, not ivregress")
		if ("`estimator'"=="cue") di as text "(WARNING: -cue- estimator is not exact, see help file)"
	}

	* For this, _iv_parse would have been useful, but I don't want to do factor expansions when parsing
	if ("`model'"=="iv") {

		* get part before parentheses
		local wrongparens 1
		while (`wrongparens') {
			gettoken tmp 0 : 0 ,p("(")
			local left `left'`tmp'
			* Avoid matching the parens of e.g. L(-1/2) and L.(var1 var2)
			* Using Mata to avoid regexm() and trim() space limitations
			mata: st_local("tmp1", subinstr(`"`0'"', " ", "") ) // wrong parens if ( and then a number
			mata: st_local("tmp2", substr(strtrim(`"`left'"'), -1) ) // wrong parens if dot
			local wrongparens = regexm(`"`tmp1'"', "^\([0-9-]") | (`"`tmp2'"'==".")
			if (`wrongparens') {
				gettoken tmp 0 : 0 ,p(")")
				local left `left'`tmp'
			}
		}

		* get part in parentheses
		gettoken right 0 : 0 ,bind match(parens)
		Assert trim(`"`0'"')=="" , msg("error: remaining argument: `0'")

		* now parse part in parentheses
		gettoken endogvars instruments : right ,p("=")
		gettoken equalsign instruments : instruments ,p("=")

		Assert "`endogvars'"!="", msg("iv: endogvars required")
		local 0 `endogvars'
		syntax varlist(fv ts numeric)
		local endogvars `varlist'

		Assert "`instruments'"!="", msg("iv: instruments required")
		local 0 `instruments'
		syntax varlist(fv ts numeric)
		local instruments `varlist'
		
		local 0 `left' // So OLS part can handle it
	}

* OLS varlist
	syntax varlist(fv ts numeric)
	gettoken depvar indepvars : varlist
	_fv_check_depvar `depvar'

* Extract format of depvar so we can format FEs like this
	fvrevar `depvar', list
	local fe_format : format `r(varlist)' // The format of the FEs that will be saved

* Variables shouldn't be repeated
* This is not perfect (e.g. doesn't deal with "x1-x10") but still helpful
	local allvars `depvar' `indepvars' `endogvars' `instruments'
	local dupvars : list dups allvars
	Assert "`dupvars'"=="", msg("error: there are repeated variables: <`dupvars'>")

* Get base variables of time and factor variables (e.g. i.foo L(1/3).bar -> foo bar)
	foreach vars in depvar indepvars endogvars instruments {
		if ("``vars''"!="") {
			fvrevar ``vars'' , list
			local basevars `basevars' `r(varlist)'
		}
	}

	local keys subcmd model ivsuite estimator depvar indepvars endogvars instruments fe_format ///
		basevars
	foreach key of local keys {
		sreturn local `key' ``key''
	}
end 

program define ParseStages, sclass
	syntax, model(string) [stages(string)] // model can't be blank at this point!
	local 0 `stages'
	syntax [namelist(name=stages)], [noSAVE] [*]
	
	if ("`stages'"=="") local stages none
	if ("`stages'"=="all") local stages iv first ols reduced acid

	if ("`stages'"!="none") {
		Assert "`model'"!="ols", msg("{cmd:stages(`stages')} not allowed with ols")
		local special iv none
		local valid_stages first ols reduced acid
		local stages : list stages - special
		local wrong_stages : list stages - valid_stages
		Assert "`wrong_stages'"=="", msg("Error, invalid stages(): `wrong_stages'")
		* The "iv" stage will be always on for IV-type regressions
		local stages `stages' iv // put it last so it does the restore
	}

	sreturn local stages `stages'
	sreturn local stage_suboptions `options'
	sreturn local savestages = ("`save'"!="nosave")
end

program define ParseVCE, sclass
	* Note: bw=1 *usually* means just do HC instead of HAC
	* BUGBUG: It is not correct to ignore the case with "bw(1) kernel(Truncated)"
	* but it's too messy to add -if-s everywhere just for this rare case (see also Mark Schaffer's email)

	syntax 	[anything(id="VCE type")] , ///
			[bw(integer 1) KERnel(string) dkraay(integer 1) kiefer] ///
			[suite(string) TWICErobust] ///
			[weighttype(string)] ///
			model(string) ///
			[ivsuite(string)]

	Assert `bw'>0, msg("VCE bandwidth must be a positive integer")
	gettoken vcetype clustervars : anything
	* Expand variable abbreviations; but this adds unwanted i. prefixes
	if ("`clustervars'"!="") {
		fvunab clustervars : `clustervars'
		local clustervars : subinstr local clustervars "i." "", all
	}

	* vcetype abbreviations:
	if (substr("`vcetype'",1,3)=="ols") local vcetype unadjusted
	if (substr("`vcetype'",1,2)=="un") local vcetype unadjusted
	if (substr("`vcetype'",1,1)=="r") local vcetype robust
	if (substr("`vcetype'",1,2)=="cl") local vcetype cluster
	if ("`vcetype'"=="conventional") local vcetype unadjusted // Conventional is the name given in e.g. xtreg
	Assert strpos("`vcetype'",",")==0, msg("Unexpected contents of VCE: <`vcetype'> has a comma")

	* Implicit defaults
	if ("`vcetype'"=="" & "`weighttype'"=="pweight") local vcetype robust
	if ("`vcetype'"=="") local vcetype unadjusted

	* Sanity checks on vcetype
	Assert inlist("`vcetype'", "unadjusted", "robust", "cluster"), ///
		msg("vcetype '`vcetype'' not allowed")

	Assert !("`vcetype'"=="unadjusted" & "`weighttype'"=="pweight"), ///
		msg("pweights do not work with vce(unadjusted), use a different vce()")
	* Recall that [pw] = [aw] + _robust http://www.stata.com/statalist/archive/2007-04/msg00282.html
	
	* Also see: http://www.stata.com/statalist/archive/2004-11/msg00275.html
	* "aweights are for cell means data, i.e. data which have been collapsed through averaging,
	* and pweights are for sampling weights"

	* Cluster vars
	local num_clusters : word count `clustervars'
	Assert inlist( (`num_clusters'>0) + ("`vcetype'"=="cluster") , 0 , 2), msg("Can't specify cluster without clustervars and viceversa") // XOR

	* VCE Suite
	local vcesuite `suite'
	if ("`vcesuite'"=="") local vcesuite default
	if ("`vcesuite'"=="default") {
		if (`bw'>1 | `dkraay'>1 | "`kiefer'"!="" | "`kernel'"!="") {
			local vcesuite avar
		}
		else if (`num_clusters'>1) {
			local vcesuite mwc
		}
	}

	Assert inlist("`vcesuite'", "default", "mwc", "avar"), msg("Wrong vce suite: `vcesuite'")

	if ("`vcesuite'"=="mwc") {
		cap findfile tuples.ado
		Assert !_rc , msg("error: -tuples- not installed, please run {stata ssc install tuples} to estimate multi-way clusters.")
	}
	
	if ("`vcesuite'"=="avar") { 
		cap findfile avar.ado
		Assert !_rc , msg("error: -avar- not installed, please run {stata ssc install avar} or change the option -vcesuite-")
	}

	* Some combinations are not coded
	Assert !("`ivsuite'"=="ivregress" & (`num_clusters'>1 | `bw'>1 | `dkraay'>1 | "`kiefer'"!="" | "`kernel'"!="") ), msg("option vce(`vce') incompatible with ivregress")
	Assert !("`ivsuite'"=="ivreg2" & (`num_clusters'>2) ), msg("ivreg2 doesn't allow more than two cluster variables")
	Assert !("`model'"=="ols" & "`vcesuite'"=="avar" & (`num_clusters'>2) ), msg("avar doesn't allow more than two cluster variables")
	Assert !("`model'"=="ols" & "`vcesuite'"=="default" & (`bw'>1 | `dkraay'>1 | "`kiefer'"!="" | "`kernel'"!="") ), msg("to use those vce options you need to use -avar- as the vce suite")
	if (`num_clusters'>0) local temp_clustervars " <CLUSTERVARS>"
	if (`bw'==1 & `dkraay'==1 & "`kernel'"!="") local kernel // No point in setting kernel here 
	if (`bw'>1 | "`kernel'"!="") local vceextra `vceextra' bw(`bw') 
	if (`dkraay'>1) local vceextra `vceextra' dkraay(`dkraay') 
	if ("`kiefer'"!="") local vceextra `vceextra' kiefer 
	if ("`kernel'"!="") local vceextra `vceextra' kernel(`kernel')
	if ("`vceextra'"!="") local vceextra , `vceextra'
	local vceoption "`vcetype'`temp_clustervars'`vceextra'" // this excludes "vce(", only has the contents

* Parse -twicerobust-
	* If true, will use wmatrix(...) vce(...) instead of wmatrix(...) vce(unadjusted)
	* The former is closer to -ivregress- but not exact, the later matches -ivreg2-
	local twicerobust = ("`twicerobust'"!="")

	local keys vceoption vcetype vcesuite vceextra num_clusters clustervars bw kernel dkraay twicerobust kiefer
	foreach key of local keys {
		sreturn local `key' ``key''
	}
end

program define ParseAbsvars, rclass
syntax anything(id="absvars" name=absvars equalok everything), [SAVEfe]
	* Logic: split absvars -> expand each into factors -> split each into parts

	local g 0
	local all_cvars
	local all_ivars

	* Convert "target = absvar" into "target=absvar"
	* Need to deal with "= " " =" "  =   " and similar cases
	while (regexm("`absvars'", "[ ][ ]+")) {
		local absvars : subinstr local absvars "  " " ", all
	}
	local absvars : subinstr local absvars " =" "=", all
	local absvars : subinstr local absvars "= " "=", all

	while ("`absvars'"!="") {
		local ++g
		gettoken absvar absvars : absvars, bind
		local target
		if strpos("`absvar'","=") gettoken target absvar : absvar, parse("=")
		if ("`target'"!="") {
			conf new var `target'
			gettoken eqsign absvar : absvar, parse("=")
		}

		local hasdot = strpos("`absvar'", ".")
		local haspound = strpos("`absvar'", "#")
		if (!`hasdot' & !`haspound') local absvar i.`absvar'
		
		local 0 `absvar'
		syntax varlist(numeric fv)
		* This will expand very aggressively:
			* EG: x##c.y -> i.x c.y i.x#c.y
			* di as error "    varlist=<`varlist'>"
		
		local ivars
		local cvars
		
		local absvar_has_intercept 0
		local has_intercept 0

		foreach factor of local varlist {
			local hasdot = strpos("`factor'", ".")
			local haspound = strpos("`factor'", "#")
			local factor_has_cvars 0

			if (!`hasdot') continue
			while ("`factor'"!="") {
				gettoken part factor : factor, parse("#")
				local is_indicator = strpos("`part'", "i.")
				local is_continuous = strpos("`part'", "c.")
				local basevar = substr("`part'", 3, .)
				if (`is_indicator') local ivars `ivars' `basevar'
				if (`is_continuous') {
					local cvars `cvars' `basevar'
					local factor_has_cvars 1
				}
			}
			if (!`factor_has_cvars') local absvar_has_intercept 1
		}
		
		local ivars : list uniq ivars
		local num_slopes : word count `cvars'
		Assert "`ivars'"!="", msg("error parsing absvars: no indicator variables in absvar <`absvar'> (expanded to `varlist')")
		local unique_cvars : list uniq cvars
		Assert (`: list unique_cvars == cvars'), msg("error parsing absvars: factor interactions such as i.x##i.y not allowed")

		local all_cvars `all_cvars' `cvars'
		local all_ivars `all_ivars' `ivars'

		if (`absvar_has_intercept') local has_intercept 1

		return local target`g' `target'
		return local ivars`g' `ivars'
		return local cvars`g' `cvars'
		return scalar has_intercept`g' = `absvar_has_intercept'
		return scalar num_slopes`g' = `num_slopes'
	
		local label : subinstr local ivars " " "#", all
		if (`num_slopes'==1) {
			local label `label'#c.`cvars'
		}
		else if (`num_slopes'>1) {
			local label `label'#c.(`cvars')
		}
		return local varlabel`g' `label'
	
	}
	
	local all_ivars : list uniq all_ivars
	local all_cvars : list uniq all_cvars

	return scalar G = `g'
	return scalar savefe = ("`savefe'"!="")
	return local all_ivars `all_ivars'
	return local all_cvars `all_cvars'
	return scalar has_intercept = `has_intercept' // 1 if the model is not a pure-intercept one
end

program define ParseDOF, sclass
	syntax, [ALL NONE] [PAIRwise FIRSTpair] [CLusters] [CONTinuous]
	opts_exclusive "`all' `none'" dofadjustments
	opts_exclusive "`pairwise' `firstpair'" dofadjustments
	if ("`none'"!="") {
		Assert "`pairwise'`firstpair'`clusters'`continuous'"=="", msg("option {bf:dofadjustments()} invalid; {bf:none} not allowed with other alternatives")
		local dofadjustments
	}
	if ("`all'"!="") {
		Assert "`pairwise'`firstpair'`clusters'`continuous'"=="", msg("option {bf:dofadjustments()} invalid; {bf:all} not allowed with other alternatives")
		local dofadjustments pairwise clusters continuous
	}
	else {
		local dofadjustments `pairwise' `firstpair' `clusters' `continuous'
	}
	sreturn local dofadjustments "`dofadjustments'"
end

program define ParseImplicit
* Parse options in the form NAME|NAME(arguments)
	* opt()			name of the option (so if opt=spam, we can have spam or spam(...))
	* default()		default value for the implicit form (in case we don't have a parenthesis)
	* syntax()		syntax of the contents of the parenthesis
	* input()		text to parse (usually `options', the result of a previous syntax .. , .. [*] )
	* inject()		what locals to inject on the caller (depend on -syntax)
	* xor			opt is mandatory (one of the two versions must occur)
	syntax, opt(name local) default(string) syntax(string asis) [input(string asis)] inject(namelist local) [xor]

	* First see if the implicit version is possible
	local lower_opt = lower("`opt'")
	local 0 , `input'
	cap syntax, `opt' [*]
	if ("`xor'"=="") local capture capture
	local rc = _rc
	if (`rc') {
		`capture' syntax, `opt'(string asis) [*]
		if ("`capture'"!="" & _rc) exit
	}
	else {
		local `lower_opt' `default'
	}
	local 0 ``lower_opt''
	syntax `syntax'
	foreach loc of local inject {
		c_local `loc' ``loc''
	}
	c_local options `options'
end

program define GenUID
	args uid
	local uid_type = cond(c(N)>c(maxlong), "double", "long")
	gen `uid_type' `uid' = _n // Useful for later merges
	la var `uid' "[UID]"
end

program define Compact, sclass
syntax, basevars(string) verbose(integer) [depvar(string) indepvars(string) endogvars(string) instruments(string)] ///
	[uid(string) timevar(string) panelvar(string) weightvar(string) weighttype(string) ///
	absorb_keepvars(string) clustervars(string)] ///
	[if(string) in(string) vceextra(string)] [savecache(integer 0) more_keepvars(varlist)]

* Drop unused variables
	local weight "`weighttype'"
	local exp "= `weightvar'"

	marksample touse, novar // Uses -if- , -in- and -exp- ; can't drop any var until this
	local cluster_keepvars `clustervars'
	local cluster_keepvars : subinstr local cluster_keepvars "#" " ", all
	local cluster_keepvars : subinstr local cluster_keepvars "i." "", all
	keep `uid' `touse' `basevars' `timevar' `panelvar' `weightvar' `absorb_keepvars' `cluster_keepvars' `more_keepvars'

* Expand factor and time-series variables
	local expandedvars
	local sets depvar indepvars endogvars instruments // depvar MUST be first
	Debug, level(4) newline
	Debug, level(4) msg("{title:Expanding factor and time-series variables:}")
	foreach set of local sets {
		local varlist ``set''
		if ("`varlist'"=="") continue
		// local original_`set' `varlist'
		* the -if- prevents creating dummies for categories that have been excluded
		ExpandFactorVariables `varlist' if `touse', setname(`set') verbose(`verbose') savecache(`savecache')
		local `set' "`r(varlist)'"
		local expandedvars `expandedvars' ``set''
	}

* Variables needed for savecache
	if (`savecache') {
		local cachevars `timevar' `panelvar'
		foreach basevar of local basevars {
			local in_expanded : list basevar in expandedvars
			if (!`in_expanded') {
				local cachevars `cachevars' `basevar'
			}
		}
		c_local cachevars `cachevars'
		if ("`cachevars'"!="") Debug, level(0) msg("(cachevars: {res}`cachevars'{txt})")
	}

* Drop unused basevars and tsset vars (usually no longer needed)
	if ("`vceextra'"!="") local tsvars `panelvar' `timevar' // We need to keep them only with autoco-robust VCE
	keep `uid' `touse' `expandedvars' `weightvar' `absorb_keepvars' `cluster_keepvars' `tsvars' `cachevars' `more_keepvars'

* Drop excluded observations and observations with missing values
	markout `touse' `expandedvars' `weightvar' `absorb_keepvars' `cluster_keepvars'
	qui keep if `touse'
	if ("`weightvar'"!="") assert `weightvar'>0 // marksample should have dropped those // if ("`weightvar'"!="") qui drop if (`weightvar'==0)
	Assert c(N)>0, rc(2000) msg("Empty sample, check for missing values or an always-false if statement")
	if ("`weightvar'"!="") {
		la var `weightvar' "[WEIGHT] `: var label `weightvar''"
	}
	foreach set of local sets {
		if ("``set''"!="") c_local `set' ``set''
	}
	c_local expandedvars `expandedvars'
end

		
// -------------------------------------------------------------------------------------------------
// Expand factor time-series variables
// -------------------------------------------------------------------------------------------------
* Steps:
* 1) Call -fvrevar-
* 2) Label newly generated temporary variables
* 3) Drop i) omitted variables, and ii) base variables (if not part of a #c.var interaction)

program define ExpandFactorVariables, rclass
syntax varlist(min=1 numeric fv ts) [if] [,setname(string)] [SAVECACHE(integer 0)] verbose(integer)
	
	* If saving the data for later regressions -savecache(..)- we will need to match each expansion to its newvars
	* The mata array is used for that
	* Note: This explains why we need to wrap -fvrevar- in a loop
	if (`savecache') {
		mata: varlist_cache = asarray_create()
		mata: asarray_notfound(varlist_cache, "")
	}

	local expanded_msg `"" - variable expansion for `setname': {res}`varlist'{txt} ->""'
	while (1) {
		gettoken factorvar varlist : varlist, bind
		if ("`factorvar'"=="") continue, break

		* Create temporary variables from time and factor expressions
		* -fvrevar- is slow so only call it if needed
		mata: st_local("hasdot", strofreal(strpos("`factorvar'", ".")>0))
		if (`hasdot') {
			fvrevar `factorvar' `if' // , stub(__V__) // stub doesn't work in Stata 11.2
			local subvarlist `r(varlist)'
		}
		else {
			local subvarlist `factorvar'
		}

		local contents
		foreach var of varlist `subvarlist' {
			LabelRenameVariable `var' // Tempvars not renamed will be dropped automatically
			if !r(is_dropped) {
				local contents `contents' `r(varname)'
				// if (`savecache') di as error `"<mata: asarray(varlist_cache, "`factorvar'", "`r(varname)'")>"'
				if (`savecache') mata: asarray(varlist_cache, "`factorvar'", asarray(varlist_cache, "`factorvar'") + " " + "`r(varname)'")
			}
			* Yellow=Already existed, White=Created, Red=NotCreated (omitted or base)
			local color = cond(r(is_dropped), "error", cond(r(is_newvar), "input", "result"))
			if (`verbose'>3) {
				local expanded_msg `"`expanded_msg' as `color' " `r(name)'" as text " (`r(varname)')""'
			}
		}
		Assert "`contents'"!="", msg("error: variable -`factorvar'- in varlist -`varlist'- in category -`setname'- is  empty after factor/time expansion")
		local newvarlist `newvarlist' `contents'
	}

	Debug, level(4) msg(`expanded_msg')
	return clear
	return local varlist "`newvarlist'"
end

program define LabelRenameVariable, rclass
syntax varname
	local var `varlist'
	local fvchar : char `var'[fvrevar]
	local tschar : char `var'[tsrevar]
	local is_newvar = ("`fvchar'`tschar'"!="") & substr("`var'", 1, 2)=="__"
	local name "`var'"
	local will_drop 0

	if (`is_newvar') {
		local name "`fvchar'`tschar'"
		local parts : subinstr local fvchar "#" " ", all
		local has_cont_interaction = strpos("`fvchar'", "c.")>0
		local is_omitted 0
		local is_base 0
		foreach part of local parts {
			if (regexm("`part'", "b.*\.")) local is_base 1
			if (regexm("`part'", "o.*\.")) local is_omitted 1
		}

		local will_drop = (`is_omitted') | (`is_base' & !`has_cont_interaction')
		if (!`will_drop') {
			char `var'[name] `name'
			la var `var' "[TEMPVAR] `name'"
			local newvar : subinstr local name "." "__", all
			local newvar : subinstr local newvar "#" "_X_", all
			* -permname- selects newname# if newname is taken (# is the first number available)
			local newvar : permname __`newvar', length(30)
			rename `var' `newvar'
			local var `newvar'
		}
	}
	else {
		char `var'[name] `var'
	}

	return scalar is_newvar = `is_newvar'
	return scalar is_dropped = `will_drop'
	return local varname "`var'"
	return local name "`name'"
end

		
// -------------------------------------------------------------
// Faster alternative to -egen group-. MVs, IF, etc not allowed!
// -------------------------------------------------------------

program define GenerateID, sortpreserve
syntax varlist(numeric) , [REPLACE Generate(name)] [CLUSTERVARS(namelist) NESTED]
assert ("`replace'"!="") + ("`generate'"!="") == 1

	foreach var of varlist `varlist' {
		assert !missing(`var')
	}

	local numvars : word count `varlist'
	if ("`replace'"!="") assert `numvars'==1 // Can't replace more than one var!
	
	// Create ID
	tempvar new_id
	sort `varlist'
	by `varlist': gen long `new_id' = (_n==1)
	qui replace `new_id' = sum(`new_id')
	qui compress `new_id'
	assert !missing(`new_id')
	
	local name = "i." + subinstr("`varlist'", " ", "#i.", .)
	char `new_id'[name] `name'
	la var `new_id' "[ID] `name'"

	// Could use these chars to speed up DropSingletons	and Wrapper_mwc
	*char `new_id'[obs] `c(N)' 
	*char `new_id'[id] 1 

	// Either replace or generate
	if ("`replace'"!="") {
		drop `varlist'
		rename `new_id' `varlist'
		local new_id `varlist' // I need to keep track of the variable for the clustervar part
	}
	else {
		rename `new_id' `generate'
		local new_id `generate'
	}

	// See if var. is nested within a clustervar
	local in_clustervar 0
	local is_clustervar 0

	if ("`clustervars'"!="") {
		
		* Check if clustervar===ID
		foreach clustervar of local clustervars {
			if ("`new_id'"=="`clustervar'") {
				local is_clustervar 1
				local nesting_clustervar "`clustervar'"
				continue, break
			}
		}
		
		* Check if ID is nested within cluster ("if two obs. belong to the same ID, they belong to the same cluster")
		if (!`is_clustervar' & "`nested'"!="") {
			tempvar same
			qui gen byte `same' = .
			foreach clustervar of local clustervars {

				* Avoid check if clustervar is another absvar
				* Reason: it would be stupid to have one absvar nested in another (same result as dropping nesting one)
				local clustervar_is_absvar = regexm("`clustervar'","__FE[0-9]+__")
				if (`clustervar_is_absvar') continue

				qui bys `new_id' (`clustervar'): replace `same' = (`clustervar'[1] == `clustervar'[_N])
				qui cou if (`same'==0)
				if r(N)==0 {
					local in_clustervar 1
					local nesting_clustervar "`clustervar'"
					continue, break
				}
			}
		}
	}

	char `new_id'[is_clustervar] `is_clustervar'
	char `new_id'[in_clustervar] `in_clustervar'
	char `new_id'[nesting_clustervar] `nesting_clustervar' 
end

// -------------------------------------------------------------------------------------------------
