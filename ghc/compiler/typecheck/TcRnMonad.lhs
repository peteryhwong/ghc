\begin{code}
module TcRnMonad(
	module TcRnMonad,
	module TcRnTypes
  ) where

#include "HsVersions.h"

import HsSyn		( MonoBinds(..) )
import HscTypes		( HscEnv(..), PersistentCompilerState(..),
			  emptyFixityEnv, emptyGlobalRdrEnv, TyThing,
			  ExternalPackageState(..), HomePackageTable,
			  ModDetails(..), HomeModInfo(..), Deprecations(..),
			  GlobalRdrEnv, LocalRdrEnv, NameCache, FixityEnv,
			  GhciMode, lookupType, unQualInScope )
import TcRnTypes
import Module		( Module, foldModuleEnv )
import Name		( Name, isInternalName )
import Type		( Type )
import NameEnv		( extendNameEnvList )
import InstEnv		( InstEnv, extendInstEnv )
import TysWiredIn	( integerTy, doubleTy )

import VarSet		( emptyVarSet )
import VarEnv		( TidyEnv, emptyTidyEnv )
import RdrName		( emptyRdrEnv )
import ErrUtils		( Message, Messages, emptyMessages, errorsFound, 
			  addShortErrLocLine, addShortWarnLocLine, printErrorsAndWarnings )
import SrcLoc		( SrcLoc, noSrcLoc )
import NameEnv		( emptyNameEnv )
import Bag		( emptyBag )
import Outputable
import UniqSupply	( UniqSupply, mkSplitUniqSupply, uniqFromSupply, splitUniqSupply )
import Unique		( Unique )
import CmdLineOpts	( DynFlags, DynFlag(..), dopt, opt_PprStyle_Debug )
import BasicTypes	( FixitySig )
import Bag		( snocBag, unionBags )

import Maybe		( isJust )
import IO		( stderr )
import DATA_IOREF	( newIORef, readIORef )
\end{code}

%************************************************************************
%*									*
	Standard combinators, but specialised for this monad
			(for efficiency)
%*									*
6%************************************************************************

\begin{code}
mappM  	      :: (a -> TcRn m b) -> [a] -> TcRn m [b]
mappM_ 	      :: (a -> TcRn m b) -> [a] -> TcRn m ()
	-- Funny names to avoid clash with Prelude
sequenceM     :: [TcRn m a] -> TcRn m [a]
foldlM        :: (a -> b -> TcRn m a)  -> a -> [b] -> TcRn m a
mapAndUnzipM  :: (a -> TcRn m (b,c))   -> [a] -> TcRn m ([b],[c])
mapAndUnzip3M :: (a -> TcRn m (b,c,d)) -> [a] -> TcRn m ([b],[c],[d])
checkM	      :: Bool -> TcRn m () -> TcRn m ()	-- Perform arg if bool is False
ifM	      :: Bool -> TcRn m () -> TcRn m ()	-- Perform arg if bool is True

mappM f []     = return []
mappM f (x:xs) = do { r <- f x; rs <- mappM f xs; return (r:rs) }

mappM_ f []     = return ()
mappM_ f (x:xs) = f x >> mappM_ f xs

sequenceM [] = return []
sequenceM (x:xs) = do { r <- x; rs <- sequenceM xs; return (r:rs) }

foldlM k z [] = return z
foldlM k z (x:xs) = do { r <- k z x; foldlM k r xs }

mapAndUnzipM f []     = return ([],[])
mapAndUnzipM f (x:xs) = do { (r,s) <- f x; 
			     (rs,ss) <- mapAndUnzipM f xs; 
			     return (r:rs, s:ss) }

mapAndUnzip3M f []     = return ([],[], [])
mapAndUnzip3M f (x:xs) = do { (r,s,t) <- f x; 
			      (rs,ss,ts) <- mapAndUnzip3M f xs; 
			      return (r:rs, s:ss, t:ts) }

checkM True  err = return ()
checkM False err = err

ifM True  do_it = do_it
ifM False do_it = return ()
\end{code}


%************************************************************************
%*									*
			initTc
%*									*
%************************************************************************

\begin{code}
initTc :: HscEnv -> PersistentCompilerState
       -> Module 
       -> TcM r
       -> IO (PersistentCompilerState, Maybe r)
		-- Nothing => error thrown by the thing inside
		-- (error messages should have been printed already)

initTc  (HscEnv { hsc_mode   = ghci_mode,
		  hsc_HPT    = hpt,
		  hsc_dflags = dflags })
	pcs mod do_this
 = do { us       <- mkSplitUniqSupply 'a' ;
      	us_var   <- newIORef us ;
      	errs_var <- newIORef (emptyBag, emptyBag) ;
      	tvs_var  <- newIORef emptyVarSet ;
	usg_var  <- newIORef emptyUsages ;
	nc_var   <- newIORef (pcs_nc pcs) ;
	eps_var  <- newIORef eps ;
   
      	let {
	     env = Env { env_top = top_env,
			 env_gbl = gbl_env,
			 env_lcl = lcl_env,
			 env_loc = noSrcLoc } ;

	     top_env = TopEnv { 
		top_mode   = ghci_mode,
		top_dflags = dflags,
		top_eps    = eps_var,
		top_hpt	   = hpt,
		top_nc	   = nc_var,
		top_us	   = us_var,
		top_errs   = errs_var } ;

	     gbl_env = TcGblEnv {
		tcg_mod      = mod,
		tcg_usages   = usg_var,
		tcg_rdr_env  = emptyGlobalRdrEnv,
		tcg_fix_env  = emptyFixityEnv,
		tcg_default  = defaultDefaultTys,
		tcg_type_env = emptyNameEnv,
		tcg_ist      = mkImpTypeEnv eps hpt,
		tcg_inst_env = mkImpInstEnv dflags eps hpt,
		tcg_exports  = [],
		tcg_imports  = emptyImportAvails,
		tcg_binds    = EmptyMonoBinds,
		tcg_deprecs  = NoDeprecs,
		tcg_insts    = [],
		tcg_rules    = [],
		tcg_fords    = [] } ;

	     lcl_env = TcLclEnv {
		tcl_ctxt   = [],
		tcl_level  = topStage,
		tcl_env    = emptyNameEnv,
		tcl_tyvars = tvs_var,
		tcl_lie	   = panic "initTc:LIE" } ;
			-- LIE only valid inside a getLIE
	     } ;
   
	-- OK, here's the business end!
	maybe_res <- catch (do { res  <- runTcRn env do_this ;
				 return (Just res) })
		 	   (\_ -> return Nothing) ;

	-- Print any error messages
	msgs <- readIORef errs_var ;
	printErrorsAndWarnings msgs ;

	-- Get final PCS and return
	eps' <- readIORef eps_var ;
	nc'  <- readIORef nc_var ;
	let { pcs' = PCS { pcs_EPS = eps', pcs_nc = nc' } ;
	      final_res | errorsFound msgs = Nothing
			| otherwise	   = maybe_res } ;

	return (pcs', final_res)
    }
  where
    eps = pcs_EPS pcs

defaultDefaultTys :: [Type]
defaultDefaultTys = [integerTy, doubleTy]

mkImpInstEnv :: DynFlags -> ExternalPackageState -> HomePackageTable -> InstEnv
mkImpInstEnv dflags eps hpt
  = foldModuleEnv (add . md_insts . hm_details) 
		  (eps_inst_env eps)
		  hpt
  where
	  -- We shouldn't get instance conflict errors from
	  -- the package and home type envs
    add dfuns inst_env = WARN( not (null errs), vcat (map snd errs) ) inst_env'
		       where
			 (inst_env', errs) = extendInstEnv dflags inst_env dfuns

-- mkImpTypeEnv makes the imported symbol table
mkImpTypeEnv :: ExternalPackageState -> HomePackageTable
 	     -> Name -> Maybe TyThing
mkImpTypeEnv pcs hpt = lookup 
  where
    pte = eps_PTE pcs
    lookup name | isInternalName name = Nothing
	        | otherwise	      = lookupType hpt pte name
\end{code}


%************************************************************************
%*									*
		Simple accessors
%*									*
%************************************************************************

\begin{code}
getTopEnv :: TcRn m TopEnv
getTopEnv = do { env <- getEnv; return (env_top env) }

getGblEnv :: TcRn m TcGblEnv
getGblEnv = do { env <- getEnv; return (env_gbl env) }

updGblEnv :: (TcGblEnv -> TcGblEnv) -> TcRn m a -> TcRn m a
updGblEnv upd = updEnv (\ env@(Env { env_gbl = gbl }) -> 
			  env { env_gbl = upd gbl })

setGblEnv :: TcGblEnv -> TcRn m a -> TcRn m a
setGblEnv gbl_env = updEnv (\ env -> env { env_gbl = gbl_env })

getLclEnv :: TcRn m m
getLclEnv = do { env <- getEnv; return (env_lcl env) }

updLclEnv :: (m -> m) -> TcRn m a -> TcRn m a
updLclEnv upd = updEnv (\ env@(Env { env_lcl = lcl }) -> 
			  env { env_lcl = upd lcl })

setLclEnv :: m -> TcRn m a -> TcRn n a
setLclEnv lcl_env = updEnv (\ env -> env { env_lcl = lcl_env })
\end{code}

Command-line flags

\begin{code}
getDOpts :: TcRn m DynFlags
getDOpts = do { env <- getTopEnv; return (top_dflags env) }

doptM :: DynFlag -> TcRn m Bool
doptM flag = do { dflags <- getDOpts; return (dopt flag dflags) }

ifOptM :: DynFlag -> TcRn m () -> TcRn m ()	-- Do it flag is true
ifOptM flag thing_inside = do { b <- doptM flag; 
				if b then thing_inside else return () }

getGhciMode :: TcRn m GhciMode
getGhciMode = do { env <- getTopEnv; return (top_mode env) }
\end{code}

\begin{code}
getSrcLocM :: TcRn m SrcLoc
	-- Avoid clash with Name.getSrcLoc
getSrcLocM = do { env <- getEnv; return (env_loc env) }

addSrcLoc :: SrcLoc -> TcRn m a -> TcRn m a
addSrcLoc loc = updEnv (\env -> env { env_loc = loc })
\end{code}

\begin{code}
getEps :: TcRn m ExternalPackageState
getEps = do { env <- getTopEnv; readMutVar (top_eps env) }

setEps :: ExternalPackageState -> TcRn m ()
setEps eps = do { env <- getTopEnv; writeMutVar (top_eps env) eps }

getHpt :: TcRn m HomePackageTable
getHpt = do { env <- getTopEnv; return (top_hpt env) }

getModule :: TcRn m Module
getModule = do { env <- getGblEnv; return (tcg_mod env) }

getGlobalRdrEnv :: TcRn m GlobalRdrEnv
getGlobalRdrEnv = do { env <- getGblEnv; return (tcg_rdr_env env) }

getFixityEnv :: TcRn m FixityEnv
getFixityEnv = do { env <- getGblEnv; return (tcg_fix_env env) }

extendFixityEnv :: [(Name,FixitySig Name)] -> RnM a -> RnM a
extendFixityEnv new_bit
  = updGblEnv (\env@(TcGblEnv { tcg_fix_env = old_fix_env }) -> 
		env {tcg_fix_env = extendNameEnvList old_fix_env new_bit})	     

getDefaultTys :: TcRn m [Type]
getDefaultTys = do { env <- getGblEnv; return (tcg_default env) }
\end{code}

\begin{code}
getUsageVar :: TcRn m (TcRef Usages)
getUsageVar = do { env <- getGblEnv; return (tcg_usages env) }

getUsages :: TcRn m Usages
getUsages = do { usg_var <- getUsageVar; readMutVar usg_var }

updUsages :: (Usages -> Usages) -> TcRn m () 
updUsages upd = do { usg_var <- getUsageVar ;
		     usg <- readMutVar usg_var ;
		     writeMutVar usg_var (upd usg) }
\end{code}


%************************************************************************
%*									*
		Error management
%*									*
%************************************************************************

\begin{code}
getErrsVar :: TcRn m (TcRef Messages)
getErrsVar = do { env <- getTopEnv; return (top_errs env) }

setErrsVar :: TcRef Messages -> TcRn m a -> TcRn m a
setErrsVar v = updEnv (\ env@(Env { env_top = top_env }) ->
			 env { env_top = top_env { top_errs = v }})

addErr :: Message -> TcRn m ()
addErr msg = do { loc <- getSrcLocM ; addErrAt loc msg }

addErrAt :: SrcLoc -> Message -> TcRn m ()
addErrAt loc msg
 = do {  errs_var <- getErrsVar ;
	 rdr_env <- getGlobalRdrEnv ;
	 let { err = addShortErrLocLine loc (unQualInScope rdr_env) msg } ;
	 (warns, errs) <- readMutVar errs_var ;
  	 writeMutVar errs_var (warns, errs `snocBag` err) }

addErrs :: [(SrcLoc,Message)] -> TcRn m ()
addErrs msgs = mappM_ add msgs
	     where
	       add (loc,msg) = addErrAt loc msg

addWarn :: Message -> TcRn m ()
addWarn msg
  = do { errs_var <- getErrsVar ;
	 loc <- getSrcLocM ;
	 rdr_env <- getGlobalRdrEnv ;
	 let { warn = addShortWarnLocLine loc (unQualInScope rdr_env) msg } ;
	 (warns, errs) <- readMutVar errs_var ;
  	 writeMutVar errs_var (warns `snocBag` warn, errs) }

checkErr :: Bool -> Message -> TcRn m ()
-- Add the error if the bool is False
checkErr ok msg = checkM ok (addErr msg)

warnIf :: Bool -> Message -> TcRn m ()
warnIf True  msg = addWarn msg
warnIf False msg = return ()

addMessages :: Messages -> TcRn m ()
addMessages (m_warns, m_errs)
  = do { errs_var <- getErrsVar ;
	 (warns, errs) <- readMutVar errs_var ;
  	 writeMutVar errs_var (warns `unionBags` m_warns,
			       errs  `unionBags` m_errs) }

checkGHCI :: Message -> TcRn m ()	-- Check that GHCI is on
					-- otherwise add the error message
#ifdef GHCI 
checkGHCI m = returnM ()
#else
checkGHCI m = addErr m
#endif
\end{code}


\begin{code}
recoverM :: TcRn m r 	-- Recovery action; do this if the main one fails
	 -> TcRn m r	-- Main action: do this first
	 -> TcRn m r
recoverM recover thing 
  = do { mb_res <- tryM thing ;
	 case mb_res of
	   Left exn  -> recover
	   Right res -> returnM res }

tryTc :: TcRn m a -> TcRn m (Messages, Maybe a)
    -- (tryTc m) executes m, and returns
    --	Just r,  if m succeeds (returning r) and caused no errors
    --	Nothing, if m fails, or caused errors
    -- It also returns all the errors accumulated by m
    -- 	(even in the Just case, there might be warnings)
    --
    -- It always succeeds (never raises an exception)
tryTc m 
 = do {	errs_var <- newMutVar emptyMessages ;
	
	mb_r <- tryM (setErrsVar errs_var m) ; 

	new_errs <- readMutVar errs_var ;

	return (new_errs, 
		case mb_r of
		  Left exn  			 -> Nothing
		  Right r | errorsFound new_errs -> Nothing
			  | otherwise		 -> Just r) 
   }

tryTcLIE :: TcM a -> TcM (Messages, Maybe a)
-- Just like tryTc, except that it ensures that the LIE
-- for the thing is propagated only if there are no errors
-- Hence it's restricted to the type-check monad
tryTcLIE thing_inside
  = do { ((errs, mb_r), lie) <- getLIE (tryTc thing_inside) ;
	 ifM (isJust mb_r) (extendLIEs lie) ;
	 return (errs, mb_r) }

tryTcLIE_ :: TcM r -> TcM r -> TcM r
-- (tryM_ r m) tries m; if it succeeds it returns it,
-- otherwise it returns r.  Any error messages added by m are discarded,
-- whether or not m succeeds.
tryTcLIE_ recover main
  = do { (_msgs, mb_res) <- tryTcLIE main ;
	 case mb_res of
	   Just res -> return res
	   Nothing  -> recover }

checkNoErrs :: TcM r -> TcM r
-- (checkNoErrs m) succeeds iff m succeeds and generates no errors
-- If m fails then (checkNoErrsTc m) fails.
-- If m succeeds, it checks whether m generated any errors messages
--	(it might have recovered internally)
-- 	If so, it fails too.
-- Regardless, any errors generated by m are propagated to the enclosing context.
checkNoErrs main
  = do { (msgs, mb_res) <- tryTcLIE main ;
	 addMessages msgs ;
	 case mb_res of
	   Just r  -> return r
	   Nothing -> failM
   }

ifErrsM :: TcRn m r -> TcRn m r -> TcRn m r
--	ifErrsM bale_out main
-- does 'bale_out' if there are errors in errors collection
-- otherwise does 'main'
ifErrsM bale_out normal
 = do { errs_var <- getErrsVar ;
	msgs <- readMutVar errs_var ;
	if errorsFound msgs then
	   bale_out
	else	
	   normal }

failIfErrsM :: TcRn m ()
-- Useful to avoid error cascades
failIfErrsM = ifErrsM failM (return ())
\end{code}

\begin{code}
forkM :: SDoc -> TcM a -> TcM (Maybe a)
-- Run thing_inside in an interleaved thread.  It gets a separate
-- 	* errs_var, and
--	* unique supply, 
-- but everything else is shared, so this is DANGEROUS.  
--
-- It returns Nothing if the computation fails
-- 
-- It's used for lazily type-checking interface
-- signatures, which is pretty benign

forkM doc thing_inside
 = do {	us <- newUniqueSupply ;
	unsafeInterleaveM $
	do { us_var <- newMutVar us ;
	     (msgs, mb_res) <- tryTcLIE (setUsVar us_var thing_inside) ;
	     case mb_res of
		Just r  -> return (Just r) 
		Nothing -> do {
		    -- Bleat about errors in the forked thread
		    ioToTcRn (do { printErrs (hdr_doc defaultErrStyle) ;
			       	   printErrorsAndWarnings msgs }) ;
		    return Nothing }
	}}
  where
    hdr_doc = text "forkM failed:" <+> doc
\end{code}


%************************************************************************
%*									*
		Unique supply
%*									*
%************************************************************************

\begin{code}
getUsVar :: TcRn m (TcRef UniqSupply)
getUsVar = do { env <- getTopEnv; return (top_us env) }

setUsVar :: TcRef UniqSupply -> TcRn m a -> TcRn m a
setUsVar v = updEnv (\ env@(Env { env_top = top_env }) ->
		       env { env_top = top_env { top_us = v }})

newUnique :: TcRn m Unique
newUnique = do { us <- newUniqueSupply ; 
		 return (uniqFromSupply us) }

newUniqueSupply :: TcRn m UniqSupply
newUniqueSupply
 = do { u_var <- getUsVar ;
	us <- readMutVar u_var ;
    	let { (us1, us2) = splitUniqSupply us } ;
	writeMutVar u_var us1 ;
	return us2 }
\end{code}


\begin{code}
getNameCache :: TcRn m NameCache
getNameCache = do { TopEnv { top_nc = nc_var } <- getTopEnv; 
		    readMutVar nc_var }

setNameCache :: NameCache -> TcRn m ()
setNameCache nc = do { TopEnv { top_nc = nc_var } <- getTopEnv; 
		       writeMutVar nc_var nc }
\end{code}


%************************************************************************
%*									*
		Debugging
%*									*
%************************************************************************

\begin{code}
traceTc, traceRn :: SDoc -> TcRn a ()
traceRn      = dumpOptTcRn Opt_D_dump_rn_trace
traceTc      = dumpOptTcRn Opt_D_dump_tc_trace
traceSplice  = dumpOptTcRn Opt_D_dump_splices
traceHiDiffs = dumpOptTcRn Opt_D_dump_hi_diffs

dumpOptTcRn :: DynFlag -> SDoc -> TcRn a ()
dumpOptTcRn flag doc = ifOptM flag (dumpTcRn doc)

dumpTcRn :: SDoc -> TcRn a ()
dumpTcRn doc = do { rdr_env <- getGlobalRdrEnv ;
		    ioToTcRn (printForUser stderr (unQualInScope rdr_env) doc) }
\end{code}


%************************************************************************
%*									*
	Context management and error message generation
	  	    for the type checker
%*									*
%************************************************************************

\begin{code}
setErrCtxtM, addErrCtxtM :: (TidyEnv -> TcM (TidyEnv, Message)) -> TcM a -> TcM a
setErrCtxtM msg = updCtxt (\ msgs -> [msg])
addErrCtxtM msg = updCtxt (\ msgs -> msg : msgs)

setErrCtxt, addErrCtxt :: Message -> TcM a -> TcM a
setErrCtxt msg = setErrCtxtM (\env -> returnM (env, msg))
addErrCtxt msg = addErrCtxtM (\env -> returnM (env, msg))

popErrCtxt :: TcM a -> TcM a
popErrCtxt = updCtxt (\ msgs -> case msgs of { [] -> []; (m:ms) -> ms })

getErrCtxt :: TcM ErrCtxt
getErrCtxt = do { env <- getLclEnv ; return (tcl_ctxt env) }

-- Helper function for the above
updCtxt :: (ErrCtxt -> ErrCtxt) -> TcM a -> TcM a
updCtxt upd = updLclEnv (\ env@(TcLclEnv { tcl_ctxt = ctxt }) -> 
			   env { tcl_ctxt = upd ctxt })

getInstLoc :: InstOrigin -> TcM InstLoc
getInstLoc origin
  = do { loc <- getSrcLocM ; env <- getLclEnv ;
	 return (origin, loc, (tcl_ctxt env)) }
\end{code}

    The addErrTc functions add an error message, but do not cause failure.
    The 'M' variants pass a TidyEnv that has already been used to
    tidy up the message; we then use it to tidy the context messages

\begin{code}
addErrTc :: Message -> TcM ()
addErrTc err_msg = addErrTcM (emptyTidyEnv, err_msg)

addErrsTc :: [Message] -> TcM ()
addErrsTc err_msgs = mappM_ addErrTc err_msgs

addErrTcM :: (TidyEnv, Message) -> TcM ()
addErrTcM (tidy_env, err_msg)
  = do { ctxt <- getErrCtxt ;
	 loc  <- getSrcLocM ;
	 add_err_tcm tidy_env err_msg loc ctxt }

addInstErrTcM :: InstLoc -> (TidyEnv, Message) -> TcM ()
addInstErrTcM inst_loc@(_, loc, ctxt) (tidy_env, err_msg)
  = add_err_tcm tidy_env err_msg loc full_ctxt
  where
    full_ctxt = (\env -> returnM (env, pprInstLoc inst_loc)) : ctxt
\end{code}

The failWith functions add an error message and cause failure

\begin{code}
failWithTc :: Message -> TcM a		     -- Add an error message and fail
failWithTc err_msg 
  = addErrTc err_msg >> failM

failWithTcM :: (TidyEnv, Message) -> TcM a   -- Add an error message and fail
failWithTcM local_and_msg
  = addErrTcM local_and_msg >> failM

checkTc :: Bool -> Message -> TcM ()	     -- Check that the boolean is true
checkTc True  err = returnM ()
checkTc False err = failWithTc err
\end{code}

	Warnings have no 'M' variant, nor failure

\begin{code}
addWarnTc :: Message -> TcM ()
addWarnTc msg
 = do { ctxt <- getErrCtxt ;
	ctxt_msgs <- do_ctxt emptyTidyEnv ctxt ;
	addWarn (vcat (msg : ctxt_to_use ctxt_msgs)) }

warnTc :: Bool -> Message -> TcM ()
warnTc warn_if_true warn_msg
  | warn_if_true = addWarnTc warn_msg
  | otherwise	 = return ()
\end{code}

 	Helper functions

\begin{code}
add_err_tcm tidy_env err_msg loc ctxt
 = do { ctxt_msgs <- do_ctxt tidy_env ctxt ;
	addErrAt loc (vcat (err_msg : ctxt_to_use ctxt_msgs)) }

do_ctxt tidy_env []
 = return []
do_ctxt tidy_env (c:cs)
 = do {	(tidy_env', m) <- c tidy_env  ;
	ms	       <- do_ctxt tidy_env' cs  ;
	return (m:ms) }

ctxt_to_use ctxt | opt_PprStyle_Debug = ctxt
		 | otherwise	      = take 3 ctxt
\end{code}

%************************************************************************
%*									*
	     Other stuff specific to type checker
%*									*
%************************************************************************

\begin{code}
getLIEVar :: TcM (TcRef LIE)
getLIEVar = do { env <- getLclEnv; return (tcl_lie env) }

setLIEVar :: TcRef LIE -> TcM a -> TcM a
setLIEVar lie_var = updLclEnv (\ env -> env { tcl_lie = lie_var })

getLIE :: TcM a -> TcM (a, [Inst])
-- (getLIE m) runs m, and returns the type constraints it generates
getLIE thing_inside
  = do { lie_var <- newMutVar emptyLIE ;
	 res <- updLclEnv (\ env -> env { tcl_lie = lie_var }) 
			  thing_inside ;
	 lie <- readMutVar lie_var ;
	 return (res, lieToList lie) }

extendLIE :: Inst -> TcM ()
extendLIE inst
  = do { lie_var <- getLIEVar ;
	 lie <- readMutVar lie_var ;
	 writeMutVar lie_var (inst `consLIE` lie) }

extendLIEs :: [Inst] -> TcM ()
extendLIEs [] 
  = returnM ()
extendLIEs insts
  = do { lie_var <- getLIEVar ;
	 lie <- readMutVar lie_var ;
	 writeMutVar lie_var (mkLIE insts `plusLIE` lie) }
\end{code}


\begin{code}
getStage :: TcM Stage
getStage = do { env <- getLclEnv; return (tcl_level env) }

setStage :: Stage -> TcM a -> TcM a 
setStage s = updLclEnv (\ env -> env { tcl_level = s })

setLclTypeEnv :: TcLclEnv -> TcM a -> TcM a
-- Set the local type envt, but do *not* disturb other fields,
-- notably the lie_var
setLclTypeEnv lcl_env thing_inside
  = updLclEnv upd thing_inside
  where
    upd env = env { tcl_env = tcl_env lcl_env,
		    tcl_tyvars = tcl_tyvars lcl_env }
\end{code}


%************************************************************************
%*									*
	     Stuff for the renamer's local env
%*									*
%************************************************************************

\begin{code}
initRn :: RnMode -> RnM a -> TcRn m a
initRn mode thing_inside
 = do { env <- getGblEnv ;
	let { lcl_env = RnLclEnv {
			     rn_mode = mode,
			     rn_lenv = emptyRdrEnv }} ;
	setLclEnv lcl_env thing_inside }
\end{code}

\begin{code}
getLocalRdrEnv :: RnM LocalRdrEnv
getLocalRdrEnv = do { env <- getLclEnv; return (rn_lenv env) }

setLocalRdrEnv :: LocalRdrEnv -> RnM a -> RnM a
setLocalRdrEnv rdr_env thing_inside 
  = updLclEnv (\env -> env {rn_lenv = rdr_env}) thing_inside

getModeRn :: RnM RnMode
getModeRn = do { env <- getLclEnv; return (rn_mode env) }
\end{code}

