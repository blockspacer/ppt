-- |C++ Code Generator Primitives
module Ppt.Generate.CpPrim where
import Ppt.Frame.ParsedRep
import Ppt.Frame.Types
import Ppt.Frame.Layout

import Prelude hiding ((<>))
import Text.PrettyPrint ((<>),(<+>))

import Control.Lens
import Data.Maybe
import Ppt.Generate.CpConfig
import qualified Data.List as L
import qualified Text.PrettyPrint as PP

--
-- Class Member Generation
--

-- |Members to go into the final declaration.  Note that these *must*
-- be kept in the order presented, as they've already had memory
-- layout applied.
data MemberData = MB { mbMethods ::[PP.Doc], mbMember :: PP.Doc, mbHeaders :: [String]
                     , mbModules :: [GenModule] }
                 -- ^Declared members in the original frame specification
                | PrivateMem { pmbMember :: PP.Doc, pmbHeaders :: [String]
                             , pmbModules :: [GenModule] }
                 -- ^PPT private stuff (sequence numbers, type descriminator)
                  deriving (Eq, Show)

-- |Breakdown of members in a given class declaration.
data QualMember = PubMember PP.Doc
                | PrivMember PP.Doc
                deriving (Eq, Show)

data Decl  = ClassDecl { cName :: String
                       , cNr :: Maybe Int
                       , cMembers :: [QualMember]
                       , cMethods :: [PP.Doc]
                       , cHeaders :: [String]
                       , cModules :: [GenModule]}
           deriving (Eq, Show)

classDecl :: String -> [MemberData] -> Decl
classDecl n [] = ClassDecl n Nothing [] [] [] []
classDecl n ((MB methods mem hdrs mods):rest) =
               let (ClassDecl _ _ pmem pmeth ns ms) = classDecl n rest
               in ClassDecl n Nothing (PubMember mem:pmem) (methods ++ pmeth) (
                 hdrs ++ ns) (mods ++ ms)
classDecl n ((PrivateMem m hdrs mods):rest) =
               let (ClassDecl _ _ pmem meth ns mds) = classDecl n rest
               in ClassDecl n Nothing (PrivMember m:pmem) meth (hdrs ++ ns) (mods ++ mds)

-- |A block of members, prefixed with a public/private block label.
-- All methods are public.
qualBlock _ [] = []
qualBlock cfg ((PubMember n):ns) =
  let isPub (PubMember _) = True
      isPub _ = False
      pubPrefix = map (\(PubMember t) -> t) $ takeWhile isPub ns
      suffix = drop (length pubPrefix) ns
  in docPublic:(formatMems cfg (n:pubPrefix)) ++ qualBlock cfg suffix
qualBlock cfg ((PrivMember n):ns) =
  let isPub (PrivMember _) = True
      isPub _ = False
      pubPrefix = map (\(PrivMember t) -> t) $ takeWhile isPub ns
      suffix = drop (length pubPrefix) ns
  in docPrivate:(formatMems cfg (n:pubPrefix)) ++ qualBlock cfg suffix

-- |Make member declarations out of a single literal (layed out) input member.
makeMember :: OutputCfg -> LayoutMember -> MemberData
makeMember cfg mem
  | has (lKind . _LKSeqno) mem || has (lKind . _LKTypeDescrim) mem  =
    let (LMember (PIntegral ty _) _ _ _ _ nm) = mem
        declType = case ty of
          PPInt -> "int"
    in PrivateMem (dataMember declType nm) [] []

  | has (lKind . _LKPadding) mem =
    let (LMember (PIntegral PPByte _) _ _ _ (LKPadding n) nm) = mem
    in  PrivateMem (dataMember "uint8_t"  (nm ++ "[" ++ show n ++ "]")) ["cstdint"] []

  | has (lKind . _LKMember) mem =
    let mt = mem ^. memPrim
        nm = mem ^. lName
    in case mt of
      PTime _ ->
        let timety = timeType cfg
            timeheaders = [timeHeader cfg]
        in MB [blockdecl cfg (PP.text $ "void snapshot_" ++ (mem ^. lName) ++ "()") PP.semi [
                  timeSave cfg nm]]
           (dataMember timety nm) timeheaders []
      PCounter _ _ ->
        let maxCounterIdx = (counterCount cfg) - 1
            indices = [0 .. maxCounterIdx]
            (LKMember frmem side) = mem ^. lKind
            baseName = fmName frmem
            bname = bufName cfg
            memSfx = if defaultInit cfg then "= 0" else ""
            elideDecls = case side of
              Nothing -> False
              Just (IntBegin 0 _) -> False
              Just (IntEnd 0 _) -> False
              _ -> True
            counterFor n = (case side of
                    Nothing -> baseName ++  "_" ++ show n
                    Just (IntBegin a b) ->
                      baseName ++ (if b > 1 then "_" ++ show n else "") ++ "_start"
                    Just (IntEnd a b) ->
                      baseName ++ (if b > 1 then "_" ++ show n else "") ++ "_end")
            functionsBaseName = case side of
              Nothing -> baseName
              Just (IntBegin _ _) -> baseName ++ "_start"
              Just (IntEnd _ _) -> baseName ++ "_end"
            saveFn = let args =
                           L.intercalate ", " $ map (\i -> "&" ++ (counterFor i)) $ indices
                         static_savectrs = blockdecl cfg (PP.text $ "void snapshot_" ++ functionsBaseName ++ "()") PP.empty [
                           stmt $ "save_counters(" ++ args ++ ")"]
                     in
                     if nativeCounters cfg
                     then
                      let labelFor n = "__ppt_" ++ bname ++ "_" ++ nm ++ "_Load_" ++ show (n+1) ++ "_counters"
                          pfxConds = [blockdecl cfg (
                                         PP.text $ "if (_ppt_ctrl == nullptr || data_" ++ bname ++ "::ppt_counter_fd[0] < 1)") PP.empty [
                                         stmt "return"],
                                      blockdecl cfg (
                                         PP.text "if ((_ppt_ctrl->client_flags & PERF_CTR_NATIVE_ENABLED) == 0)") PP.empty [
                                         stmt $ "save_counters(" ++ args ++ ")"]
                                     ]
                          condFor n = blockdecl cfg (PP.text $ "if (data_" ++ bname ++ "::ppt_counter_fd[" ++
                                                     show n ++ "] > 0)") PP.empty [
                            stmt $ "goto " ++ labelFor n
                            ]
                          sfxCond = blockdecl cfg (PP.text "else") PP.empty [ stmt $ "goto " ++ labelFor 0 ]
                          condCat conds = PP.vcat (head conds : (map (\c -> PP.text "else " <> c) $ tail conds))
                          loadFor n = [PP.text (labelFor n) <> ":",
                                       stmt $ "__asm__ volatile(\"rdpmc\" :  \"=a\" (a), \"=d\" (d) : \"c\" (data_" ++
                                          bname ++ "::ppt_counter_rcx[" ++ show n ++ "]))",
                                       stmt $ counterFor n ++ " = a | (static_cast<uint64_t>(d) << 32ULL)" ]
                          revIndices = reverse indices
                      in blockdecl cfg (PP.text $ "void snapshot_" ++ functionsBaseName ++ "()") PP.empty (
                        pfxConds ++
                        ( condCat (map condFor $ init revIndices)
                        : sfxCond
                        : stmt "uint32_t a,d":concatMap loadFor revIndices))
                    else
                      static_savectrs
            headers = [ "sys/mman.h" | nativeCounters cfg ]
        in MB [saveFn | not elideDecls] (dataMember "uint64_t" (nm ++ memSfx)) headers [GMCounters]
      PRational ty _ -> let declType = case ty of
                                         PPDouble -> "double"
                                         PPFloat -> "float"
                            memSfx = if defaultInit cfg then " = 0" else ""
                        in MB [] (dataMember declType (nm ++ memSfx)) [] []

      PIntegral ty _ -> let declType = case ty of
                                         PPByte -> "uint8_t"
                                         PPInt -> "int32_t"
                            memSfx = if defaultInit cfg then " = 0" else ""
                        in MB [] (dataMember declType (nm ++ memSfx)) [] []

sequenceDecls :: [Decl] -> [Decl]
sequenceDecls frameDecls =
  if length frameDecls > 1
  then map (\(frame, index) -> frame { cNr = Just index }) $ zip frameDecls [1..]
  else frameDecls

makeFrameDecl :: OutputCfg -> FrameLayout -> Decl
makeFrameDecl cfg (FLayout nm fr layoutmems) =
  let mems = map (makeMember cfg) layoutmems
  in classDecl nm mems


--
-- Low Level Text Generation Operations
--
semify cfg (e:es) = (PP.nest (indent cfg) e <> PP.semi):semify cfg es
semify _ [] = []

docPublic = PP.text "public:"
docPrivate = PP.text "private:"

enquote :: String -> String
enquote s =  "\"" ++ s ++ "\""

enbracket :: String -> String
enbracket s =  "<" ++ s ++ ">"

indentify cfg (e:es) = (PP.nest (indent cfg) e):indentify cfg es
indentify _ [] = []

formatMems cfg (e:es) = (PP.nest (indent cfg) e <> PP.semi):formatMems cfg es
formatMems _ [] = []

-- |Clearly can only work for simple types.  No arrays.
dataMember :: String -> String -> PP.Doc
dataMember ty name = PP.text ty <+> PP.text name

-- |Generates a block declaration that's collapsable.
blockdecl :: OutputCfg -> PP.Doc -> PP.Doc -> [PP.Doc] ->PP.Doc
blockdecl cfg name sep elems =
  let sfxElems = map (<> sep) elems
  in PP.sep [(name <+> PP.lbrace), PP.nest (indent cfg) (PP.sep sfxElems), PP.rbrace]

-- |Non-collapsable block decl.
blockdeclV :: OutputCfg -> PP.Doc -> PP.Doc -> [PP.Doc] ->PP.Doc
blockdeclV cfg name sep elems =
  let sfxElems = map (<> sep) elems
  in PP.vcat [(name <+> PP.lbrace), PP.nest (indent cfg) (PP.sep sfxElems), PP.rbrace]

funccall :: OutputCfg -> PP.Doc -> [PP.Doc] -> PP.Doc
funccall cfg name args =
  let prefix = name <+> PP.lparen
      prefixlen = length $ PP.render prefix
  in PP.hang (name <+> PP.lparen) prefixlen $ PP.hsep $ (L.intersperse PP.comma args) ++ [PP.rparen]

includeHeaders :: [String] -> [PP.Doc]
includeHeaders (h:hs) =
  (mconcat $ map PP.text ["#include <", h, ">"]):includeHeaders hs
includeHeaders [] = []

docConcat xs = PP.text $ concat xs
docConcatSp xs = PP.text $ L.intercalate " " xs

quoteString :: String -> String
quoteString str =
  qs str
  where qs (c:cs)
          | c == '"' = "\\\"" ++ (qs cs)
          | c == '\\' = "\\\\" ++ (qs cs)
          | otherwise = c:(qs cs)
        qs [] = []

stmt :: String -> PP.Doc
stmt s = PP.text s <> PP.semi

