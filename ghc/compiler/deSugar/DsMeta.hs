-----------------------------------------------------------------------------
-- The purpose of this module is to transform an HsExpr into a CoreExpr which
-- when evaluated, returns a (Meta.Q Meta.Exp) computation analogous to the
-- input HsExpr. We do this in the DsM monad, which supplies access to
-- CoreExpr's of the "smart constructors" of the Meta.Exp datatype.
--
-- It also defines a bunch of knownKeyNames, in the same way as is done
-- in prelude/PrelNames.  It's much more convenient to do it here, becuase
-- otherwise we have to recompile PrelNames whenever we add a Name, which is
-- a Royal Pain (triggers other recompilation).
-----------------------------------------------------------------------------


module DsMeta( dsBracket, dsReify,
	       templateHaskellNames, qTyConName, 
	       liftName, exprTyConName, declTyConName,
	       decTyConName, typTyConName ) where

#include "HsVersions.h"

import {-# SOURCE #-}	DsExpr ( dsExpr )

import DsUtils    ( mkListExpr, mkStringLit, mkCoreTup,
		    mkIntExpr, mkCharExpr )
import DsMonad

import qualified Language.Haskell.THSyntax as M

import HsSyn  	  ( Pat(..), HsExpr(..), Stmt(..), HsLit(..), HsOverLit(..),
		    Match(..), GRHSs(..), GRHS(..), HsBracket(..),
                    HsStmtContext(ListComp,DoExpr), ArithSeqInfo(..),
		    HsBinds(..), MonoBinds(..), HsConDetails(..),
		    TyClDecl(..), HsGroup(..),
		    HsReify(..), ReifyFlavour(..), 
		    HsType(..), HsContext(..), HsPred(..), HsTyOp(..),
	 	    HsTyVarBndr(..), Sig(..), ForeignDecl(..),
		    InstDecl(..), ConDecl(..), BangType(..),
		    PendingSplice, splitHsInstDeclTy,
		    placeHolderType, tyClDeclNames,
		    collectHsBinders, collectPatBinders, collectPatsBinders,
		    hsTyVarName, hsConArgs, getBangType,
		    toHsType
		  )

import PrelNames  ( mETA_META_Name, varQual, tcQual )
import MkIface	  ( ifaceTyThing )
import Name       ( Name, nameOccName, nameModule )
import OccName	  ( isDataOcc, isTvOcc, occNameUserString )
import Module	  ( moduleUserString )
import Id         ( Id, idType )
import NameEnv
import NameSet
import Type       ( Type, TyThing(..), mkGenTyConApp )
import TyCon	  ( DataConDetails(..) )
import TysWiredIn ( stringTy )
import CoreSyn
import CoreUtils  ( exprType )
import SrcLoc	  ( noSrcLoc )
import Maybe	  ( catMaybes )
import Panic	  ( panic )
import Unique	  ( mkPreludeTyConUnique, mkPreludeMiscIdUnique )
import BasicTypes ( NewOrData(..), StrictnessMark(..) ) 

import Outputable
import FastString	( mkFastString )
 
-----------------------------------------------------------------------------
dsBracket :: HsBracket Name -> [PendingSplice] -> DsM CoreExpr
-- Returns a CoreExpr of type M.Expr
-- The quoted thing is parameterised over Name, even though it has
-- been type checked.  We don't want all those type decorations!

dsBracket brack splices
  = dsExtendMetaEnv new_bit (do_brack brack)
  where
    new_bit = mkNameEnv [(n, Splice e) | (n,e) <- splices]

    do_brack (ExpBr e)  = do { MkC e1  <- repE e      ; return e1 }
    do_brack (PatBr p)  = do { MkC p1  <- repP p      ; return p1 }
    do_brack (TypBr t)  = do { MkC t1  <- repTy t     ; return t1 }
    do_brack (DecBr ds) = do { MkC ds1 <- repTopDs ds ; return ds1 }

-----------------------------------------------------------------------------
dsReify :: HsReify Id -> DsM CoreExpr
-- Returns a CoreExpr of type 	reifyType --> M.Typ
--				reifyDecl --> M.Dec
--				reifyFixty --> M.Fix
dsReify (ReifyOut ReifyType name)
  = do { thing <- dsLookupGlobal name ;
		-- By deferring the lookup until now (rather than doing it
		-- in the type checker) we ensure that all zonking has
		-- been done.
	 case thing of
	    AnId id -> do { MkC e <- repTy (toHsType (idType id)) ;
			    return e }
	    other   -> pprPanic "dsReify: reifyType" (ppr name)
	}

dsReify r@(ReifyOut ReifyDecl name)
  = do { thing <- dsLookupGlobal name ;
	 mb_d <- repTyClD (ifaceTyThing thing) ;
	 case mb_d of
	   Just (MkC d) -> return d 
	   Nothing	-> pprPanic "dsReify" (ppr r)
	}

{- -------------- Examples --------------------

  [| \x -> x |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (var x1)


  [| \x -> $(f [| x |]) |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (f (var x1))
-}


-------------------------------------------------------
-- 			Declarations
-------------------------------------------------------

repTopDs :: HsGroup Name -> DsM (Core [M.Decl])
repTopDs group
 = do { let { bndrs = groupBinders group } ;
	ss    <- mkGenSyms bndrs ;

	decls <- addBinds ss (do {
			val_ds <- rep_binds (hs_valds group) ;
			tycl_ds <- mapM repTyClD (hs_tyclds group) ;
			inst_ds <- mapM repInstD (hs_instds group) ;
			-- more needed
			return (val_ds ++ catMaybes tycl_ds ++ inst_ds) }) ;

	core_list <- coreList declTyConName decls ;
	wrapNongenSyms ss core_list
	-- Do *not* gensym top-level binders
      }

groupBinders (HsGroup { hs_valds = val_decls, hs_tyclds = tycl_decls,
			hs_fords = foreign_decls })
  = collectHsBinders val_decls ++
    [n | d <- tycl_decls, (n,_) <- tyClDeclNames d] ++
    [n | ForeignImport n _ _ _ _ <- foreign_decls]


repTyClD :: TyClDecl Name -> DsM (Maybe (Core M.Decl))

repTyClD (TyData { tcdND = DataType, tcdCtxt = [], 
		   tcdName = tc, tcdTyVars = tvs, 
		   tcdCons = DataCons cons, tcdDerivs = mb_derivs }) 
 = do { tc1  <- lookupBinder tc ;
	tvs1  <- repTvs tvs ;
	cons1 <- mapM repC cons ;
	cons2 <- coreList consTyConName cons1 ;
	derivs1 <- repDerivs mb_derivs ;
	dec <- repData tc1 tvs1 cons2 derivs1 ;
	return (Just dec) }

repTyClD (ClassDecl { tcdCtxt = cxt, tcdName = cls, 
		      tcdTyVars = tvs, tcdFDs = [], 
		      tcdSigs = sigs, tcdMeths = Just binds
	})
 = do { cls1 <- lookupBinder cls ;
	tvs1 <- repTvs tvs ;
	cxt1 <- repCtxt cxt ;
	sigs1  <- rep_sigs sigs ;
	binds1 <- rep_monobind binds ;
	decls1 <- coreList declTyConName (sigs1 ++ binds1) ;
	dec <- repClass cxt1 cls1 tvs1 decls1 ;
	return (Just dec) }

-- Un-handled cases
repTyClD d = do { addDsWarn (hang msg 4 (ppr d)) ;
	          return Nothing
	     }
  where
    msg = ptext SLIT("Cannot desugar this Template Haskell declaration:")

repInstD (InstDecl ty binds _ _ loc)
	-- Ignore user pragmas for now
 = do { cxt1 <- repCtxt cxt ;
	inst_ty1 <- repPred (HsClassP cls tys) ;
	binds1 <- rep_monobind binds ;
	decls1 <- coreList declTyConName binds1 ;
	repInst cxt1 inst_ty1 decls1  }
 where
   (tvs, cxt, cls, tys) = splitHsInstDeclTy ty


-------------------------------------------------------
-- 			Constructors
-------------------------------------------------------

repC :: ConDecl Name -> DsM (Core M.Cons)
repC (ConDecl con [] [] details loc)
  = do { con1     <- lookupBinder con ;
	 arg_tys  <- mapM (repBangTy con) (hsConArgs details) ;
	 arg_tys1 <- coreList typeTyConName arg_tys ;
	 repConstr con1 arg_tys1 }

repBangTy con (BangType NotMarkedStrict ty) = repTy ty
repBangTy con bty = do { addDsWarn msg ; repTy (getBangType bty) }
   where
     msg = ptext SLIT("Ignoring stricness on argument of constructor")
		 <+> quotes (ppr con)

-------------------------------------------------------
-- 			Deriving clause
-------------------------------------------------------

repDerivs :: Maybe (HsContext Name) -> DsM (Core [String])
repDerivs Nothing = return (coreList' stringTy [])
repDerivs (Just ctxt)
  = do { strs <- mapM rep_deriv ctxt ; 
	 return (coreList' stringTy strs) }
  where
    rep_deriv :: HsPred Name -> DsM (Core String)
	-- Deriving clauses must have the simple H98 form
    rep_deriv (HsClassP cls []) = lookupOcc cls
    rep_deriv other		= panic "rep_deriv"


-------------------------------------------------------
--   Signatures in a class decl, or a group of bindings
-------------------------------------------------------

rep_sigs :: [Sig Name] -> DsM [Core M.Decl]
	-- We silently ignore ones we don't recognise
rep_sigs sigs = do { sigs1 <- mapM rep_sig sigs ;
		     return (concat sigs1) }

rep_sig :: Sig Name -> DsM [Core M.Decl]
	-- Singleton => Ok
	-- Empty     => Too hard, signature ignored
rep_sig (ClassOpSig nm _ ty _) = rep_proto nm ty
rep_sig (Sig nm ty _)	       = rep_proto nm ty
rep_sig other		       = return []

rep_proto nm ty = do { nm1 <- lookupBinder nm ; 
		       ty1 <- repTy ty ; 
		       sig <- repProto nm1 ty1 ;
		       return [sig] }


-------------------------------------------------------
-- 			Types
-------------------------------------------------------

repTvs :: [HsTyVarBndr Name] -> DsM (Core [String])
repTvs tvs = do { tvs1 <- mapM (localVar . hsTyVarName) tvs ;
		  return (coreList' stringTy tvs1) } 

-----------------
repCtxt :: HsContext Name -> DsM (Core M.Ctxt)
repCtxt ctxt = do { preds <- mapM repPred ctxt; 
		    coreList typeTyConName preds }

-----------------
repPred :: HsPred Name -> DsM (Core M.Type)
repPred (HsClassP cls tys)
  = do { tc1 <- lookupOcc cls; tcon <- repNamedTyCon tc1;
	 tys1 <- repTys tys; repTapps tcon tys1 }
repPred (HsIParam _ _) = panic "No implicit parameters yet"

-----------------
repTys :: [HsType Name] -> DsM [Core M.Type]
repTys tys = mapM repTy tys

-----------------
repTy :: HsType Name -> DsM (Core M.Type)

repTy (HsTyVar n)
  | isTvOcc (nameOccName n) = do { tv1 <- localVar n ; repTvar tv1 }
  | otherwise		    = do { tc1 <- lookupOcc n; repNamedTyCon tc1 }
repTy (HsAppTy f a) = do { f1 <- repTy f ; a1 <- repTy a ; repTapp f1 a1 }
repTy (HsFunTy f a) = do { f1 <- repTy f ; a1 <- repTy a ; 
			   tcon <- repArrowTyCon ; repTapps tcon [f1,a1] }
repTy (HsListTy t)  = do { t1 <- repTy t ; tcon <- repListTyCon ; repTapp tcon t1 }
repTy (HsTupleTy tc tys)	  = do { tys1 <- repTys tys; 
					 tcon <- repTupleTyCon (length tys);
					 repTapps tcon tys1 }
repTy (HsOpTy ty1 HsArrow ty2) 	  = repTy (HsFunTy ty1 ty2)
repTy (HsOpTy ty1 (HsTyOp n) ty2) = repTy ((HsTyVar n `HsAppTy` ty1) `HsAppTy` ty2)
repTy (HsParTy t)  	       	  = repTy t
repTy (HsPredTy (HsClassP c tys)) = repTy (foldl HsAppTy (HsTyVar c) tys)

repTy other_ty = pprPanic "repTy" (ppr other_ty)	-- HsForAllTy, HsKindSig

-----------------------------------------------------------------------------      
-- 		Expressions
-----------------------------------------------------------------------------      

repEs :: [HsExpr Name] -> DsM (Core [M.Expr])
repEs es = do { es'  <- mapM repE es ;
		coreList exprTyConName es' }

repE :: HsExpr Name -> DsM (Core M.Expr)
repE (HsVar x)
  = do { mb_val <- dsLookupMetaEnv x 
       ; case mb_val of
	  Nothing	   -> do { str <- globalVar x
				 ; repVarOrCon x str }
	  Just (Bound y)   -> repVarOrCon x (coreVar y)
	  Just (Splice e)  -> do { e' <- dsExpr e
				 ; return (MkC e') } }

repE (HsIPVar x)    = panic "Can't represent implicit parameters"
repE (HsLit l)      = do { a <- repLiteral l;           repLit a }
repE (HsOverLit l)  = do { a <- repOverloadedLiteral l; repLit a }

repE (HsSplice n e loc) 
  = do { mb_val <- dsLookupMetaEnv n
       ; case mb_val of
	     Just (Splice e) -> do { e' <- dsExpr e
				   ; return (MkC e') }
	     other	     -> pprPanic "HsSplice" (ppr n) }
			

repE (HsLam m)      = repLambda m
repE (HsApp x y)    = do {a <- repE x; b <- repE y; repApp a b}
repE (NegApp x nm)  = panic "No negate yet"
repE (SectionL x y) = do { a <- repE x; b <- repE y; repSectionL a b } 
repE (SectionR x y) = do { a <- repE x; b <- repE y; repSectionR a b } 

repE (OpApp e1 (HsVar op) fix e2)
  =  do { arg1 <- repE e1; 
	  arg2 <- repE e2; 
	  the_op <- lookupOcc op ;
	  repInfixApp arg1 the_op arg2 } 

repE (HsCase e ms loc)
  = do { arg <- repE e
       ; ms2 <- mapM repMatchTup ms
       ; repCaseE arg (nonEmptyCoreList ms2) }

-- 	I havn't got the types here right yet
repE (HsDo DoExpr sts _ ty loc)      = do { (ss,zs) <- repSts sts; 
					    e       <- repDoE (nonEmptyCoreList zs);
					    wrapGenSyns expTyConName ss e }
repE (HsDo ListComp sts _ ty loc) = do { (ss,zs) <- repSts sts; 
					  e       <- repComp (nonEmptyCoreList zs);
					  wrapGenSyns expTyConName ss e }

repE (ArithSeqIn (From e)) 		= do { ds1 <- repE e; repFrom ds1 }
repE (ArithSeqIn (FromThen e1 e2))      = do { ds1 <- repE e1; ds2 <- repE e2; 
					       repFromThen ds1 ds2 }
repE (ArithSeqIn (FromTo   e1 e2))      = do { ds1 <- repE e1; ds2 <- repE e2; 
					       repFromTo   ds1 ds2 }
repE (ArithSeqIn (FromThenTo e1 e2 e3)) = do { ds1 <- repE e1; ds2 <- repE e2; 
					       ds3 <- repE e3; repFromThenTo ds1 ds2 ds3 }

repE (HsIf x y z loc) = do { a <- repE x; b <- repE y; c <- repE z; repCond a b c } 

repE (HsLet bs e) = do { (ss,ds) <- repBinds bs
		       ; e2 <- addBinds ss (repE e)
		       ; z <- repLetE ds e2
		       ; wrapGenSyns expTyConName ss z }
repE (ExplicitList ty es)     = do { xs <- repEs es; repListExp xs } 
repE (ExplicitTuple es boxed) = do { xs <- repEs es; repTup xs }

repE (HsWith _ _ _) 	    = panic "No with for implicit parameters yet"
repE (ExplicitPArr ty es)   = panic "No parallel arrays yet"
repE (RecordConOut _ _ _)   = panic "No record construction yet"
repE (RecordUpdOut _ _ _ _) = panic "No record update yet"
repE (ExprWithTySig e ty)   = panic "No expressions with type signatures yet"


-----------------------------------------------------------------------------
-- Building representations of auxillary structures like Match, Clause, Stmt, 

repMatchTup ::  Match Name -> DsM (Core M.Mtch) 
repMatchTup (Match [p] ty (GRHSs guards wheres ty2)) = 
  do { ss1 <- mkGenSyms (collectPatBinders p) 
     ; addBinds ss1 $ do {
     ; p1 <- repP p
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
     ; gs    <- repGuards guards
     ; match <- repMatch p1 gs ds
     ; wrapGenSyns matTyConName (ss1++ss2) match }}}

repClauseTup ::  Match Name -> DsM (Core M.Clse)
repClauseTup (Match ps ty (GRHSs guards wheres ty2)) = 
  do { ss1 <- mkGenSyms (collectPatsBinders ps) 
     ; addBinds ss1 $ do {
       ps1 <- repPs ps
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
       gs <- repGuards guards
     ; clause <- repClause ps1 gs ds
     ; wrapGenSyns clsTyConName (ss1++ss2) clause }}}

repGuards ::  [GRHS Name] ->  DsM (Core M.Rihs)
repGuards [GRHS [ResultStmt e loc] loc2] 
  = do {a <- repE e; repNormal a }
repGuards other 
  = do { zs <- mapM process other; 
	 repGuarded (nonEmptyCoreList (map corePair zs)) }
  where 
    process (GRHS [ExprStmt e1 ty loc,ResultStmt e2 _] _)
           = do { x <- repE e1; y <- repE e2; return (x, y) }
    process other = panic "Non Haskell 98 guarded body"


-----------------------------------------------------------------------------
-- Representing Stmt's is tricky, especially if bound variables
-- shaddow each other. Consider:  [| do { x <- f 1; x <- f x; g x } |]
-- First gensym new names for every variable in any of the patterns.
-- both static (x'1 and x'2), and dynamic ((gensym "x") and (gensym "y"))
-- if variables didn't shaddow, the static gensym wouldn't be necessary
-- and we could reuse the original names (x and x).
--
-- do { x'1 <- gensym "x"
--    ; x'2 <- gensym "x"   
--    ; doE [ BindSt (pvar x'1) [| f 1 |]
--          , BindSt (pvar x'2) [| f x |] 
--          , NoBindSt [| g x |] 
--          ]
--    }

-- The strategy is to translate a whole list of do-bindings by building a
-- bigger environment, and a bigger set of meta bindings 
-- (like:  x'1 <- gensym "x" ) and then combining these with the translations
-- of the expressions within the Do
      
-----------------------------------------------------------------------------
-- The helper function repSts computes the translation of each sub expression
-- and a bunch of prefix bindings denoting the dynamic renaming.

repSts :: [Stmt Name] -> DsM ([GenSymBind], [Core M.Stmt])
repSts [ResultStmt e loc] = 
   do { a <- repE e
      ; e1 <- repNoBindSt a
      ; return ([], [e1]) }
repSts (BindStmt p e loc : ss) =
   do { e2 <- repE e 
      ; ss1 <- mkGenSyms (collectPatBinders p) 
      ; addBinds ss1 $ do {
      ; p1 <- repP p; 
      ; (ss2,zs) <- repSts ss
      ; z <- repBindSt p1 e2
      ; return (ss1++ss2, z : zs) }}
repSts (LetStmt bs : ss) =
   do { (ss1,ds) <- repBinds bs
      ; z <- repLetSt ds
      ; (ss2,zs) <- addBinds ss1 (repSts ss)
      ; return (ss1++ss2, z : zs) } 
repSts (ExprStmt e ty loc : ss) =       
   do { e2 <- repE e
      ; z <- repNoBindSt e2 
      ; (ss2,zs) <- repSts ss
      ; return (ss2, z : zs) }
repSts other = panic "Exotic Stmt in meta brackets"      


-----------------------------------------------------------
--			Bindings
-----------------------------------------------------------

repBinds :: HsBinds Name -> DsM ([GenSymBind], Core [M.Decl]) 
repBinds decs
 = do { let { bndrs = collectHsBinders decs } ;
	ss	  <- mkGenSyms bndrs ;
	core      <- addBinds ss (rep_binds decs) ;
	core_list <- coreList declTyConName core ;
	return (ss, core_list) }

rep_binds :: HsBinds Name -> DsM [Core M.Decl] 
rep_binds EmptyBinds = return []
rep_binds (ThenBinds x y)
 = do { core1 <- rep_binds x
      ; core2 <- rep_binds y
      ; return (core1 ++ core2) }
rep_binds (MonoBind bs sigs _)
 = do { core1 <- rep_monobind bs
      ;	core2 <- rep_sigs sigs
      ;	return (core1 ++ core2) }

rep_monobind :: MonoBinds Name -> DsM [Core M.Decl]
rep_monobind EmptyMonoBinds     = return []
rep_monobind (AndMonoBinds x y) = do { x1 <- rep_monobind x; 
				       y1 <- rep_monobind y; 
				       return (x1 ++ y1) }

-- Note GHC treats declarations of a variable (not a pattern) 
-- e.g.  x = g 5 as a Fun MonoBinds. This is indicated by a single match 
-- with an empty list of patterns
rep_monobind (FunMonoBind fn infx [Match [] ty (GRHSs guards wheres ty2)] loc) 
 = do { (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
	; fn' <- lookupBinder fn
	; p   <- repPvar fn'
	; ans <- repVal p guardcore wherecore
	; return [ans] }

rep_monobind (FunMonoBind fn infx ms loc)
 =   do { ms1 <- mapM repClauseTup ms
	; fn' <- lookupBinder fn
        ; ans <- repFun fn' (nonEmptyCoreList ms1)
        ; return [ans] }

rep_monobind (PatMonoBind pat (GRHSs guards wheres ty2) loc)
 =   do { patcore <- repP pat 
        ; (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
        ; ans <- repVal patcore guardcore wherecore
        ; return [ans] }

rep_monobind (VarMonoBind v e)  
 =   do { v' <- lookupBinder v 
	; e2 <- repE e
        ; x <- repNormal e2
        ; patcore <- repPvar v'
	; empty_decls <- coreList declTyConName [] 
        ; ans <- repVal patcore x empty_decls
        ; return [ans] }

-----------------------------------------------------------------------------
-- Since everything in a MonoBind is mutually recursive we need rename all
-- all the variables simultaneously. For example: 
-- [| AndMonoBinds (f x = x + g 2) (g x = f 1 + 2) |] would translate to
-- do { f'1 <- gensym "f"
--    ; g'2 <- gensym "g"
--    ; [ do { x'3 <- gensym "x"; fun f'1 [pvar x'3] [| x + g2 |]},
--        do { x'4 <- gensym "x"; fun g'2 [pvar x'4] [| f 1 + 2 |]}
--      ]}
-- This requires collecting the bindings (f'1 <- gensym "f"), and the 
-- environment ( f |-> f'1 ) from each binding, and then unioning them 
-- together. As we do this we collect GenSymBinds's which represent the renamed 
-- variables bound by the Bindings. In order not to lose track of these 
-- representations we build a shadow datatype MB with the same structure as 
-- MonoBinds, but which has slots for the representations


-----------------------------------------------------------------------------
-- GHC allows a more general form of lambda abstraction than specified
-- by Haskell 98. In particular it allows guarded lambda's like : 
-- (\  x | even x -> 0 | odd x -> 1) at the moment we can't represent this in
-- Haskell Template's Meta.Exp type so we punt if it isn't a simple thing like
-- (\ p1 .. pn -> exp) by causing an error.  

repLambda :: Match Name -> DsM (Core M.Expr)
repLambda (Match ps _ (GRHSs [GRHS [ResultStmt e _ ] _ ] 
		             EmptyBinds _))
 = do { let bndrs = collectPatsBinders ps ;
      ; ss <- mkGenSyms bndrs
      ; lam <- addBinds ss (
		do { xs <- repPs ps; body <- repE e; repLam xs body })
      ; wrapGenSyns expTyConName ss lam }

repLambda z = panic "Can't represent a guarded lambda in Template Haskell"  

  
-----------------------------------------------------------------------------
--			Patterns
-- repP deals with patterns.  It assumes that we have already
-- walked over the pattern(s) once to collect the binders, and 
-- have extended the environment.  So every pattern-bound 
-- variable should already appear in the environment.

-- Process a list of patterns
repPs :: [Pat Name] -> DsM (Core [M.Patt])
repPs ps = do { ps' <- mapM repP ps ;
		coreList pattTyConName ps' }

repP :: Pat Name -> DsM (Core M.Patt)
repP (WildPat _)     = repPwild 
repP (LitPat l)      = do { l2 <- repLiteral l; repPlit l2 }
repP (VarPat x)      = do { x' <- lookupBinder x; repPvar x' }
repP (LazyPat p)     = do { p1 <- repP p; repPtilde p1 }
repP (AsPat x p)     = do { x' <- lookupBinder x; p1 <- repP p; repPaspat x' p1 }
repP (ParPat p)      = repP p 
repP (ListPat ps _)  = repListPat ps
repP (TuplePat ps _) = do { qs <- repPs ps; repPtup qs }
repP (ConPatIn dc details)
 = do { con_str <- lookupOcc dc
      ; case details of
         PrefixCon ps   -> do { qs <- repPs ps; repPcon con_str qs }
         RecCon pairs   -> error "No records in template haskell yet"
         InfixCon p1 p2 -> do { qs <- repPs [p1,p2]; repPcon con_str qs }
   }
repP other = panic "Exotic pattern inside meta brackets"

repListPat :: [Pat Name] -> DsM (Core M.Patt)     
repListPat [] 	  = do { nil_con <- coreStringLit "[]"
		       ; nil_args <- coreList pattTyConName [] 
	               ; repPcon nil_con nil_args }
repListPat (p:ps) = do { p2 <- repP p 
		       ; ps2 <- repListPat ps
		       ; cons_con <- coreStringLit ":"
		       ; repPcon cons_con (nonEmptyCoreList [p2,ps2]) }


----------------------------------------------------------
--	The meta-environment

type GenSymBind = (Name, Id)	-- Gensym the string and bind it to the Id
				-- I.e.		(x, x_id) means
				--	let x_id = gensym "x" in ...

addBinds :: [GenSymBind] -> DsM a -> DsM a
addBinds bs m = dsExtendMetaEnv (mkNameEnv [(n,Bound id) | (n,id) <- bs]) m

lookupBinder :: Name -> DsM (Core String)
lookupBinder n 
  = do { mb_val <- dsLookupMetaEnv n;
	 case mb_val of
	    Just (Bound id) -> return (MkC (Var id))
	    other	    -> pprPanic "Failed binder lookup:" (ppr n) }

mkGenSym :: Name -> DsM GenSymBind
mkGenSym nm = do { id <- newUniqueId nm stringTy; return (nm,id) }

mkGenSyms :: [Name] -> DsM [GenSymBind]
mkGenSyms ns = mapM mkGenSym ns
	     
lookupType :: Name 	-- Name of type constructor (e.g. M.Expr)
	   -> DsM Type	-- The type
lookupType tc_name = do { tc <- dsLookupTyCon tc_name ;
		          return (mkGenTyConApp tc []) }

-- wrapGenSyns [(nm1,id1), (nm2,id2)] y 
--	--> bindQ (gensym nm1) (\ id1 -> 
--	    bindQ (gensym nm2 (\ id2 -> 
--	    y))

wrapGenSyns :: Name 	-- Name of the type (consructor) for 'a'
	    -> [GenSymBind] 
	    -> Core (M.Q a) -> DsM (Core (M.Q a))
wrapGenSyns tc_name binds body@(MkC b)
  = do { elt_ty <- lookupType tc_name
       ; go elt_ty binds }
  where
    go elt_ty [] = return body
    go elt_ty ((name,id) : binds)
      = do { MkC body'  <- go elt_ty binds
	   ; lit_str    <- localVar name
	   ; gensym_app <- repGensym lit_str
	   ; repBindQ stringTy elt_ty 
		      gensym_app (MkC (Lam id body')) }

-- Just like wrapGenSym, but don't actually do the gensym
-- Instead use the existing name
-- Only used for [Decl]
wrapNongenSyms :: [GenSymBind] 
	       -> Core [M.Decl] -> DsM (Core [M.Decl])
wrapNongenSyms binds body@(MkC b)
  = go binds
  where
    go [] = return body
    go ((name,id) : binds)
      = do { MkC body'   <- go binds
	   ; MkC lit_str <- localVar name	-- No gensym
	   ; return (MkC (Let (NonRec id lit_str) body'))
	   }

void = placeHolderType

string :: String -> HsExpr Id
string s = HsLit (HsString (mkFastString s))


-- %*********************************************************************
-- %*									*
--		Constructing code
-- %*									*
-- %*********************************************************************

-----------------------------------------------------------------------------
-- PHANTOM TYPES for consistency. In order to make sure we do this correct 
-- we invent a new datatype which uses phantom types.

newtype Core a = MkC CoreExpr
unC (MkC x) = x

rep2 :: Name -> [ CoreExpr ] -> DsM (Core a)
rep2 n xs = do { id <- dsLookupGlobalId n
               ; return (MkC (foldl App (Var id) xs)) }

-- Then we make "repConstructors" which use the phantom types for each of the
-- smart constructors of the Meta.Meta datatypes.


-- %*********************************************************************
-- %*									*
--		The 'smart constructors'
-- %*									*
-- %*********************************************************************

--------------- Patterns -----------------
repPlit   :: Core M.Lit -> DsM (Core M.Patt) 
repPlit (MkC l) = rep2 plitName [l]

repPvar :: Core String -> DsM (Core M.Patt)
repPvar (MkC s) = rep2 pvarName [s]

repPtup :: Core [M.Patt] -> DsM (Core M.Patt)
repPtup (MkC ps) = rep2 ptupName [ps]

repPcon   :: Core String -> Core [M.Patt] -> DsM (Core M.Patt)
repPcon (MkC s) (MkC ps) = rep2 pconName [s, ps]

repPtilde :: Core M.Patt -> DsM (Core M.Patt)
repPtilde (MkC p) = rep2 ptildeName [p]

repPaspat :: Core String -> Core M.Patt -> DsM (Core M.Patt)
repPaspat (MkC s) (MkC p) = rep2 paspatName [s, p]

repPwild  :: DsM (Core M.Patt)
repPwild = rep2 pwildName []

--------------- Expressions -----------------
repVarOrCon :: Name -> Core String -> DsM (Core M.Expr)
repVarOrCon vc str | isDataOcc (nameOccName vc) = repCon str
	           | otherwise 		        = repVar str

repVar :: Core String -> DsM (Core M.Expr)
repVar (MkC s) = rep2 varName [s] 

repCon :: Core String -> DsM (Core M.Expr)
repCon (MkC s) = rep2 conName [s] 

repLit :: Core M.Lit -> DsM (Core M.Expr)
repLit (MkC c) = rep2 litName [c] 

repApp :: Core M.Expr -> Core M.Expr -> DsM (Core M.Expr)
repApp (MkC x) (MkC y) = rep2 appName [x,y] 

repLam :: Core [M.Patt] -> Core M.Expr -> DsM (Core M.Expr)
repLam (MkC ps) (MkC e) = rep2 lamName [ps, e]

repTup :: Core [M.Expr] -> DsM (Core M.Expr)
repTup (MkC es) = rep2 tupName [es]

repCond :: Core M.Expr -> Core M.Expr -> Core M.Expr -> DsM (Core M.Expr)
repCond (MkC x) (MkC y) (MkC z) =  rep2 condName [x,y,z] 

repLetE :: Core [M.Decl] -> Core M.Expr -> DsM (Core M.Expr)
repLetE (MkC ds) (MkC e) = rep2 letEName [ds, e] 

repCaseE :: Core M.Expr -> Core [M.Mtch] -> DsM( Core M.Expr)
repCaseE (MkC e) (MkC ms) = rep2 caseEName [e, ms]

repDoE :: Core [M.Stmt] -> DsM (Core M.Expr)
repDoE (MkC ss) = rep2 doEName [ss]

repComp :: Core [M.Stmt] -> DsM (Core M.Expr)
repComp (MkC ss) = rep2 compName [ss]

repListExp :: Core [M.Expr] -> DsM (Core M.Expr)
repListExp (MkC es) = rep2 listExpName [es]

repInfixApp :: Core M.Expr -> Core String -> Core M.Expr -> DsM (Core M.Expr)
repInfixApp (MkC x) (MkC y) (MkC z) = rep2 infixAppName [x,y,z]

repSectionL :: Core M.Expr -> Core M.Expr -> DsM (Core M.Expr)
repSectionL (MkC x) (MkC y) = rep2 infixAppName [x,y]

repSectionR :: Core M.Expr -> Core M.Expr -> DsM (Core M.Expr)
repSectionR (MkC x) (MkC y) = rep2 infixAppName [x,y]

------------ Right hand sides (guarded expressions) ----
repGuarded :: Core [(M.Expr, M.Expr)] -> DsM (Core M.Rihs)
repGuarded (MkC pairs) = rep2 guardedName [pairs]

repNormal :: Core M.Expr -> DsM (Core M.Rihs)
repNormal (MkC e) = rep2 normalName [e]

------------- Statements -------------------
repBindSt :: Core M.Patt -> Core M.Expr -> DsM (Core M.Stmt)
repBindSt (MkC p) (MkC e) = rep2 bindStName [p,e]

repLetSt :: Core [M.Decl] -> DsM (Core M.Stmt)
repLetSt (MkC ds) = rep2 letStName [ds]

repNoBindSt :: Core M.Expr -> DsM (Core M.Stmt)
repNoBindSt (MkC e) = rep2 noBindStName [e]

-------------- DotDot (Arithmetic sequences) -----------
repFrom :: Core M.Expr -> DsM (Core M.Expr)
repFrom (MkC x) = rep2 fromName [x]

repFromThen :: Core M.Expr -> Core M.Expr -> DsM (Core M.Expr)
repFromThen (MkC x) (MkC y) = rep2 fromThenName [x,y]

repFromTo :: Core M.Expr -> Core M.Expr -> DsM (Core M.Expr)
repFromTo (MkC x) (MkC y) = rep2 fromToName [x,y]

repFromThenTo :: Core M.Expr -> Core M.Expr -> Core M.Expr -> DsM (Core M.Expr)
repFromThenTo (MkC x) (MkC y) (MkC z) = rep2 fromThenToName [x,y,z]

------------ Match and Clause Tuples -----------
repMatch :: Core M.Patt -> Core M.Rihs -> Core [M.Decl] -> DsM (Core M.Mtch)
repMatch (MkC p) (MkC bod) (MkC ds) = rep2 matchName [p, bod, ds]

repClause :: Core [M.Patt] -> Core M.Rihs -> Core [M.Decl] -> DsM (Core M.Clse)
repClause (MkC ps) (MkC bod) (MkC ds) = rep2 clauseName [ps, bod, ds]

-------------- Dec -----------------------------
repVal :: Core M.Patt -> Core M.Rihs -> Core [M.Decl] -> DsM (Core M.Decl)
repVal (MkC p) (MkC b) (MkC ds) = rep2 valName [p, b, ds]

repFun :: Core String -> Core [M.Clse] -> DsM (Core M.Decl)  
repFun (MkC nm) (MkC b) = rep2 funName [nm, b]

repData :: Core String -> Core [String] -> Core [M.Cons] -> Core [String] -> DsM (Core M.Decl)
repData (MkC nm) (MkC tvs) (MkC cons) (MkC derivs) = rep2 dataDName [nm, tvs, cons, derivs]

repInst :: Core M.Ctxt -> Core M.Type -> Core [M.Decl] -> DsM (Core M.Decl)
repInst (MkC cxt) (MkC ty) (MkC ds) = rep2 instName [cxt, ty, ds]

repClass :: Core M.Ctxt -> Core String -> Core [String] -> Core [M.Decl] -> DsM (Core M.Decl)
repClass (MkC cxt) (MkC cls) (MkC tvs) (MkC ds) = rep2 classDName [cxt, cls, tvs, ds]

repProto :: Core String -> Core M.Type -> DsM (Core M.Decl)
repProto (MkC s) (MkC ty) = rep2 protoName [s, ty]

repConstr :: Core String -> Core [M.Type] -> DsM (Core M.Cons)
repConstr (MkC con) (MkC tys) = rep2 constrName [con,tys]

------------ Types -------------------

repTvar :: Core String -> DsM (Core M.Type)
repTvar (MkC s) = rep2 tvarName [s]

repTapp :: Core M.Type -> Core M.Type -> DsM (Core M.Type)
repTapp (MkC t1) (MkC t2) = rep2 tappName [t1,t2]

repTapps :: Core M.Type -> [Core M.Type] -> DsM (Core M.Type)
repTapps f []     = return f
repTapps f (t:ts) = do { f1 <- repTapp f t; repTapps f1 ts }

--------- Type constructors --------------

repNamedTyCon :: Core String -> DsM (Core M.Type)
repNamedTyCon (MkC s) = rep2 namedTyConName [s]

repTupleTyCon :: Int -> DsM (Core M.Type)
-- Note: not Core Int; it's easier to be direct here
repTupleTyCon i = rep2 tupleTyConName [mkIntExpr (fromIntegral i)]

repArrowTyCon :: DsM (Core M.Type)
repArrowTyCon = rep2 arrowTyConName []

repListTyCon :: DsM (Core M.Type)
repListTyCon = rep2 listTyConName []


----------------------------------------------------------
--		Literals

repLiteral :: HsLit -> DsM (Core M.Lit)
repLiteral (HsInt i)  = rep2 intLName [mkIntExpr i]
repLiteral (HsChar c) = rep2 charLName [mkCharExpr c]
repLiteral x = panic "trying to represent exotic literal"

repOverloadedLiteral :: HsOverLit -> DsM(Core M.Lit)
repOverloadedLiteral (HsIntegral i _)   = rep2 intLName [mkIntExpr i]
repOverloadedLiteral (HsFractional f _) = panic "Cant do fractional literals yet"

              
--------------- Miscellaneous -------------------

repLift :: Core e -> DsM (Core M.Expr)
repLift (MkC x) = rep2 liftName [x]

repGensym :: Core String -> DsM (Core (M.Q String))
repGensym (MkC lit_str) = rep2 gensymName [lit_str]

repBindQ :: Type -> Type	-- a and b
	 -> Core (M.Q a) -> Core (a -> M.Q b) -> DsM (Core (M.Q b))
repBindQ ty_a ty_b (MkC x) (MkC y) 
  = rep2 bindQName [Type ty_a, Type ty_b, x, y] 

------------ Lists and Tuples -------------------
-- turn a list of patterns into a single pattern matching a list

coreList :: Name	-- Of the TyCon of the element type
	 -> [Core a] -> DsM (Core [a])
coreList tc_name es 
  = do { elt_ty <- lookupType tc_name; return (coreList' elt_ty es) }

coreList' :: Type 	-- The element type
	  -> [Core a] -> Core [a]
coreList' elt_ty es = MkC (mkListExpr elt_ty (map unC es ))

nonEmptyCoreList :: [Core a] -> Core [a]
  -- The list must be non-empty so we can get the element type
  -- Otherwise use coreList
nonEmptyCoreList [] 	      = panic "coreList: empty argument"
nonEmptyCoreList xs@(MkC x:_) = MkC (mkListExpr (exprType x) (map unC xs))

corePair :: (Core a, Core b) -> Core (a,b)
corePair (MkC x, MkC y) = MkC (mkCoreTup [x,y])

lookupOcc :: Name -> DsM (Core String)
-- Lookup an occurrence; it can't be a splice.
-- Use the in-scope bindings if they exist
lookupOcc n
  = do {  mb_val <- dsLookupMetaEnv n ;
          case mb_val of
		Nothing        -> globalVar n
		Just (Bound x) -> return (coreVar x)
		other	       -> pprPanic "repE:lookupOcc" (ppr n) 
    }

globalVar :: Name -> DsM (Core String)
globalVar n = coreStringLit (name_mod ++ ":" ++ name_occ)
 	    where
	      name_mod = moduleUserString (nameModule n)
	      name_occ = occNameUserString (nameOccName n)

localVar :: Name -> DsM (Core String)
localVar n = coreStringLit (occNameUserString (nameOccName n))

coreStringLit :: String -> DsM (Core String)
coreStringLit s = do { z <- mkStringLit s; return(MkC z) }

coreVar :: Id -> Core String	-- The Id has type String
coreVar id = MkC (Var id)



-- %************************************************************************
-- %*									*
--		The known-key names for Template Haskell
-- %*									*
-- %************************************************************************

-- To add a name, do three things
-- 
--  1) Allocate a key
--  2) Make a "Name"
--  3) Add the name to knownKeyNames

templateHaskellNames :: NameSet
-- The names that are implicitly mentioned by ``bracket''
-- Should stay in sync with the import list of DsMeta
templateHaskellNames
  = mkNameSet [ intLName,charLName, plitName, pvarName, ptupName, 
		pconName, ptildeName, paspatName, pwildName, 
                varName, conName, litName, appName, infixEName, lamName,
                tupName, doEName, compName, 
                listExpName, condName, letEName, caseEName,
                infixAppName, sectionLName, sectionRName, guardedName, normalName,
		bindStName, letStName, noBindStName, parStName,
		fromName, fromThenName, fromToName, fromThenToName,
		funName, valName, liftName,
	  	gensymName, returnQName, bindQName, 
		matchName, clauseName, funName, valName, dataDName, classDName,
		instName, protoName, tvarName, tconName, tappName, 
		arrowTyConName, tupleTyConName, listTyConName, namedTyConName,
		constrName,
		exprTyConName, declTyConName, pattTyConName, mtchTyConName, 
		clseTyConName, stmtTyConName, consTyConName, typeTyConName,
		qTyConName, expTyConName, matTyConName, clsTyConName,
		decTyConName, typTyConName ]



intLName       = varQual mETA_META_Name FSLIT("intL")          intLIdKey
charLName      = varQual mETA_META_Name FSLIT("charL")         charLIdKey
plitName       = varQual mETA_META_Name FSLIT("plit")          plitIdKey
pvarName       = varQual mETA_META_Name FSLIT("pvar")          pvarIdKey
ptupName       = varQual mETA_META_Name FSLIT("ptup")          ptupIdKey
pconName       = varQual mETA_META_Name FSLIT("pcon")          pconIdKey
ptildeName     = varQual mETA_META_Name FSLIT("ptilde")        ptildeIdKey
paspatName     = varQual mETA_META_Name FSLIT("paspat")        paspatIdKey
pwildName      = varQual mETA_META_Name FSLIT("pwild")         pwildIdKey
varName        = varQual mETA_META_Name FSLIT("var")           varIdKey
conName        = varQual mETA_META_Name FSLIT("con")           conIdKey
litName        = varQual mETA_META_Name FSLIT("lit")           litIdKey
appName        = varQual mETA_META_Name FSLIT("app")           appIdKey
infixEName     = varQual mETA_META_Name FSLIT("infixE")        infixEIdKey
lamName        = varQual mETA_META_Name FSLIT("lam")           lamIdKey
tupName        = varQual mETA_META_Name FSLIT("tup")           tupIdKey
doEName        = varQual mETA_META_Name FSLIT("doE")           doEIdKey
compName       = varQual mETA_META_Name FSLIT("comp")          compIdKey
listExpName    = varQual mETA_META_Name FSLIT("listExp")       listExpIdKey
condName       = varQual mETA_META_Name FSLIT("cond")          condIdKey
letEName       = varQual mETA_META_Name FSLIT("letE")          letEIdKey
caseEName      = varQual mETA_META_Name FSLIT("caseE")         caseEIdKey
infixAppName   = varQual mETA_META_Name FSLIT("infixApp")      infixAppIdKey
sectionLName   = varQual mETA_META_Name FSLIT("sectionL")      sectionLIdKey
sectionRName   = varQual mETA_META_Name FSLIT("sectionR")      sectionRIdKey
guardedName    = varQual mETA_META_Name FSLIT("guarded")       guardedIdKey
normalName     = varQual mETA_META_Name FSLIT("normal")        normalIdKey
bindStName     = varQual mETA_META_Name FSLIT("bindSt")        bindStIdKey
letStName      = varQual mETA_META_Name FSLIT("letSt")         letStIdKey
noBindStName   = varQual mETA_META_Name FSLIT("noBindSt")      noBindStIdKey
parStName      = varQual mETA_META_Name FSLIT("parSt")         parStIdKey
fromName       = varQual mETA_META_Name FSLIT("from")          fromIdKey
fromThenName   = varQual mETA_META_Name FSLIT("fromThen")      fromThenIdKey
fromToName     = varQual mETA_META_Name FSLIT("fromTo")        fromToIdKey
fromThenToName = varQual mETA_META_Name FSLIT("fromThenTo")    fromThenToIdKey
liftName       = varQual mETA_META_Name FSLIT("lift")          liftIdKey
gensymName     = varQual mETA_META_Name FSLIT("gensym")        gensymIdKey
returnQName    = varQual mETA_META_Name FSLIT("returnQ")       returnQIdKey
bindQName      = varQual mETA_META_Name FSLIT("bindQ")         bindQIdKey

-- type Mat = ...
matchName      = varQual mETA_META_Name FSLIT("match")         matchIdKey

-- type Cls = ...
clauseName     = varQual mETA_META_Name FSLIT("clause")        clauseIdKey

-- data Dec = ...
funName        = varQual mETA_META_Name FSLIT("fun")           funIdKey
valName        = varQual mETA_META_Name FSLIT("val")           valIdKey
dataDName      = varQual mETA_META_Name FSLIT("dataD")         dataDIdKey
classDName     = varQual mETA_META_Name FSLIT("classD")        classDIdKey
instName       = varQual mETA_META_Name FSLIT("inst")          instIdKey
protoName      = varQual mETA_META_Name FSLIT("proto")         protoIdKey

-- data Typ = ...
tvarName       = varQual mETA_META_Name FSLIT("tvar")          tvarIdKey
tconName       = varQual mETA_META_Name FSLIT("tcon")          tconIdKey
tappName       = varQual mETA_META_Name FSLIT("tapp")          tappIdKey

-- data Tag = ...
arrowTyConName = varQual mETA_META_Name FSLIT("arrowTyCon")   arrowIdKey
tupleTyConName = varQual mETA_META_Name FSLIT("tupleTyCon")   tupleIdKey
listTyConName  = varQual mETA_META_Name FSLIT("listTyCon")    listIdKey
namedTyConName = varQual mETA_META_Name FSLIT("namedTyCon")   namedTyConIdKey

-- data Con = ...
constrName     = varQual mETA_META_Name FSLIT("constr")        constrIdKey

exprTyConName  = tcQual  mETA_META_Name FSLIT("Expr")  	       exprTyConKey
declTyConName  = tcQual  mETA_META_Name FSLIT("Decl")  	       declTyConKey
pattTyConName  = tcQual  mETA_META_Name FSLIT("Patt")  	       pattTyConKey
mtchTyConName  = tcQual  mETA_META_Name FSLIT("Mtch")  	       mtchTyConKey
clseTyConName  = tcQual  mETA_META_Name FSLIT("Clse")  	       clseTyConKey
stmtTyConName  = tcQual  mETA_META_Name FSLIT("Stmt") 	       stmtTyConKey
consTyConName  = tcQual  mETA_META_Name FSLIT("Cons")  	       consTyConKey
typeTyConName  = tcQual  mETA_META_Name FSLIT("Type")  	       typeTyConKey

qTyConName     = tcQual  mETA_META_Name FSLIT("Q")  	       qTyConKey
expTyConName   = tcQual  mETA_META_Name FSLIT("Exp")  	       expTyConKey
decTyConName   = tcQual  mETA_META_Name FSLIT("Dec")  	       decTyConKey
typTyConName   = tcQual  mETA_META_Name FSLIT("Typ")  	       typTyConKey
matTyConName   = tcQual  mETA_META_Name FSLIT("Mat")  	       matTyConKey
clsTyConName   = tcQual  mETA_META_Name FSLIT("Cls")  	       clsTyConKey

--	TyConUniques available: 100-119
-- 	Check in PrelNames if you want to change this

expTyConKey  = mkPreludeTyConUnique 100
matTyConKey  = mkPreludeTyConUnique 101
clsTyConKey  = mkPreludeTyConUnique 102
qTyConKey    = mkPreludeTyConUnique 103
exprTyConKey = mkPreludeTyConUnique 104
declTyConKey = mkPreludeTyConUnique 105
pattTyConKey = mkPreludeTyConUnique 106
mtchTyConKey = mkPreludeTyConUnique 107
clseTyConKey = mkPreludeTyConUnique 108
stmtTyConKey = mkPreludeTyConUnique 109
consTyConKey = mkPreludeTyConUnique 110
typeTyConKey = mkPreludeTyConUnique 111
typTyConKey  = mkPreludeTyConUnique 112
decTyConKey  = mkPreludeTyConUnique 113



-- 	IdUniques available: 200-299
-- 	If you want to change this, make sure you check in PrelNames
fromIdKey       = mkPreludeMiscIdUnique 200
fromThenIdKey   = mkPreludeMiscIdUnique 201
fromToIdKey     = mkPreludeMiscIdUnique 202
fromThenToIdKey = mkPreludeMiscIdUnique 203
liftIdKey       = mkPreludeMiscIdUnique 204
gensymIdKey     = mkPreludeMiscIdUnique 205
returnQIdKey    = mkPreludeMiscIdUnique 206
bindQIdKey      = mkPreludeMiscIdUnique 207
funIdKey        = mkPreludeMiscIdUnique 208
valIdKey        = mkPreludeMiscIdUnique 209
protoIdKey      = mkPreludeMiscIdUnique 210
matchIdKey      = mkPreludeMiscIdUnique 211
clauseIdKey     = mkPreludeMiscIdUnique 212
intLIdKey       = mkPreludeMiscIdUnique 213
charLIdKey      = mkPreludeMiscIdUnique 214

classDIdKey     = mkPreludeMiscIdUnique 215
instIdKey       = mkPreludeMiscIdUnique 216
dataDIdKey      = mkPreludeMiscIdUnique 217


plitIdKey       = mkPreludeMiscIdUnique 220
pvarIdKey       = mkPreludeMiscIdUnique 221
ptupIdKey       = mkPreludeMiscIdUnique 222
pconIdKey       = mkPreludeMiscIdUnique 223
ptildeIdKey     = mkPreludeMiscIdUnique 224
paspatIdKey     = mkPreludeMiscIdUnique 225
pwildIdKey      = mkPreludeMiscIdUnique 226
varIdKey        = mkPreludeMiscIdUnique 227
conIdKey        = mkPreludeMiscIdUnique 228
litIdKey        = mkPreludeMiscIdUnique 229
appIdKey        = mkPreludeMiscIdUnique 230
infixEIdKey     = mkPreludeMiscIdUnique 231
lamIdKey        = mkPreludeMiscIdUnique 232
tupIdKey        = mkPreludeMiscIdUnique 233
doEIdKey        = mkPreludeMiscIdUnique 234
compIdKey       = mkPreludeMiscIdUnique 235
listExpIdKey    = mkPreludeMiscIdUnique 237
condIdKey       = mkPreludeMiscIdUnique 238
letEIdKey       = mkPreludeMiscIdUnique 239
caseEIdKey      = mkPreludeMiscIdUnique 240
infixAppIdKey   = mkPreludeMiscIdUnique 241
sectionLIdKey   = mkPreludeMiscIdUnique 242
sectionRIdKey   = mkPreludeMiscIdUnique 243
guardedIdKey    = mkPreludeMiscIdUnique 244
normalIdKey     = mkPreludeMiscIdUnique 245
bindStIdKey     = mkPreludeMiscIdUnique 246
letStIdKey      = mkPreludeMiscIdUnique 247
noBindStIdKey   = mkPreludeMiscIdUnique 248
parStIdKey      = mkPreludeMiscIdUnique 249

tvarIdKey	= mkPreludeMiscIdUnique 250
tconIdKey	= mkPreludeMiscIdUnique 251
tappIdKey	= mkPreludeMiscIdUnique 252

arrowIdKey	= mkPreludeMiscIdUnique 253
tupleIdKey	= mkPreludeMiscIdUnique 254
listIdKey	= mkPreludeMiscIdUnique 255
namedTyConIdKey	= mkPreludeMiscIdUnique 256

constrIdKey	= mkPreludeMiscIdUnique 257

-- %************************************************************************
-- %*									*
--		Other utilities
-- %*									*
-- %************************************************************************

-- It is rather usatisfactory that we don't have a SrcLoc
addDsWarn :: SDoc -> DsM ()
addDsWarn msg = dsWarn (noSrcLoc, msg)