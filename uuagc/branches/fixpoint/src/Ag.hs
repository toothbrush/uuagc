module Main where

import System.Environment            (getArgs, getProgName)
import System.Exit                   (exitFailure)
import System.Console.GetOpt         (usageInfo)
import Data.List                     (isSuffixOf,nub)
import Control.Monad                 (zipWithM_)
import Data.Maybe

import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Sequence as Seq ((><))
import Data.Foldable(toList)
import Pretty

import UU.Parsing                    (Message(..), Action(..))
import UU.Scanner.Position           (Pos, line, file)
import UU.Scanner.Token              (Token)

import qualified Transform          as Pass1  (sem_AG     ,  wrap_AG     ,  Syn_AG      (..), Inh_AG      (..))
import qualified Desugar            as Pass1a (sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..))
import qualified DefaultRules       as Pass2  (sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..))
import qualified ResolveLocals      as Pass2a (sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..))
import qualified Order              as Pass3  (sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..))
import qualified KWOrder            as Pass3a (sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..))
import qualified GenerateCode       as Pass4  (sem_CGrammar, wrap_CGrammar, Syn_CGrammar(..), Inh_CGrammar(..))
import qualified PrintVisitCode     as Pass4a (sem_CGrammar, wrap_CGrammar, Syn_CGrammar(..), Inh_CGrammar(..))
import qualified ExecutionPlan2Hs   as Pass4b (sem_ExecutionPlan, wrap_ExecutionPlan, Syn_ExecutionPlan(..), Inh_ExecutionPlan(..))
import qualified PrintCode          as Pass5  (sem_Program,  wrap_Program,  Syn_Program (..), Inh_Program (..))
import qualified PrintOcamlCode     as Pass5a (sem_Program,  wrap_Program,  Syn_Program (..), Inh_Program (..))
import qualified PrintErrorMessages as PrErr  (sem_Errors ,  wrap_Errors ,  Syn_Errors  (..), Inh_Errors  (..), isError)
import qualified TfmToVisage        as PassV  (sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..))

import qualified AbstractSyntaxDump as GrammarDump (sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..))
import qualified CodeSyntaxDump as CGrammarDump (sem_CGrammar,  wrap_CGrammar,  Syn_CGrammar (..), Inh_CGrammar (..))
import qualified Visage as VisageDump (sem_VisageGrammar, wrap_VisageGrammar, Syn_VisageGrammar(..), Inh_VisageGrammar(..))
import qualified AG2AspectAG as AspectAGDump (pragmaAspectAG, sem_Grammar,  wrap_Grammar,  Syn_Grammar (..), Inh_Grammar (..)) --marcos

import Options
import Version       (banner)
import Parser        (parseAG, depsAG, parseAGI)
import ErrorMessages (Error(ParserError), Errors)
import CommonTypes
import ATermWrite


main :: IO ()
main
 = do args     <- getArgs
      progName <- getProgName

      let usageheader = "Usage info:\n " ++ progName ++ " options file ...\n\nList of options:"
          (flags,files,errs) = getOptions args

      if showVersion flags
       then putStrLn banner
       else if null files || showHelp flags || (not.null) errs
       then mapM_ putStrLn (usageInfo usageheader options : errs)
       else if genFileDeps flags
            then reportDeps flags files
            else zipWithM_ (compile flags) files (outputFiles flags++repeat "")


compile :: Options -> String -> String -> IO ()
compile flags input output
 = do (output0,parseErrors) <- parseAG flags (searchPath flags) (inputFile input)
      irrefutableMap <- readIrrefutableMap flags

      let output1   = Pass1.wrap_AG              (Pass1.sem_AG                                 output0 ) Pass1.Inh_AG       {Pass1.options_Inh_AG       = flags}
          flags'    = condDisableOptimizations (Pass1.pragmas_Syn_AG output1 flags)
          grammar1  = Pass1.output_Syn_AG        output1
          output1a  = Pass1a.wrap_Grammar        (Pass1a.sem_Grammar grammar1                          ) Pass1a.Inh_Grammar {Pass1a.options_Inh_Grammar = flags', Pass1a.forcedIrrefutables_Inh_Grammar = irrefutableMap }
          grammar1a =Pass1a.output_Syn_Grammar   output1a
          output2   = Pass2.wrap_Grammar         (Pass2.sem_Grammar grammar1a                          ) Pass2.Inh_Grammar  {Pass2.options_Inh_Grammar  = flags'}
          grammar2  = Pass2.output_Syn_Grammar   output2
          outputV   = PassV.wrap_Grammar         (PassV.sem_Grammar grammar2                           ) PassV.Inh_Grammar  {}
          grammarV  = PassV.visage_Syn_Grammar   outputV
          output2a  = Pass2a.wrap_Grammar        (Pass2a.sem_Grammar grammar2                          ) Pass2a.Inh_Grammar {Pass2a.options_Inh_Grammar = flags'}
          grammar2a = Pass2a.output_Syn_Grammar  output2a
          output3   = Pass3.wrap_Grammar         (Pass3.sem_Grammar grammar2a                          ) Pass3.Inh_Grammar  {Pass3.options_Inh_Grammar  = flags'}
          grammar3  = Pass3.output_Syn_Grammar   output3
          output3a  = Pass3a.wrap_Grammar        (Pass3a.sem_Grammar grammar2a                         ) Pass3a.Inh_Grammar  {Pass3a.options_Inh_Grammar  = flags'}
          grammar3a = Pass3a.output_Syn_Grammar  output3a
          output4   = Pass4.wrap_CGrammar        (Pass4.sem_CGrammar(Pass3.output_Syn_Grammar  output3)) Pass4.Inh_CGrammar {Pass4.options_Inh_CGrammar = flags'}
          output4a  = Pass4a.wrap_CGrammar       (Pass4a.sem_CGrammar(Pass3.output_Syn_Grammar output3)) Pass4a.Inh_CGrammar {Pass4a.options_Inh_CGrammar = flags'}
          output4b  = Pass4b.wrap_ExecutionPlan  (Pass4b.sem_ExecutionPlan grammar3a) Pass4b.Inh_ExecutionPlan {Pass4b.options_Inh_ExecutionPlan = flags', Pass4b.inhmap_Inh_ExecutionPlan = Pass3a.inhmap_Syn_Grammar output3a, Pass4b.synmap_Inh_ExecutionPlan = Pass3a.synmap_Syn_Grammar output3a, Pass4b.pragmaBlocks_Inh_ExecutionPlan = pragmaBlocksTxt, Pass4b.importBlocks_Inh_ExecutionPlan = importBlocksTxt, Pass4b.textBlocks_Inh_ExecutionPlan = textBlocksDoc, Pass4b.moduleHeader_Inh_ExecutionPlan = mkModuleHeader $ Pass1.moduleDecl_Syn_AG output1, Pass4b.mainName_Inh_ExecutionPlan = mkMainName mainName $ Pass1.moduleDecl_Syn_AG output1, Pass4b.mainFile_Inh_ExecutionPlan = mainFile, Pass4b.optionsLine_Inh_ExecutionPlan = optionsLine}
          output5   = Pass5.wrap_Program         (Pass5.sem_Program (Pass4.output_Syn_CGrammar output4)) Pass5.Inh_Program  {Pass5.options_Inh_Program  = flags', Pass5.pragmaBlocks_Inh_Program = pragmaBlocksTxt, Pass5.importBlocks_Inh_Program = importBlocksTxt, Pass5.textBlocks_Inh_Program = textBlocksDoc, Pass5.textBlockMap_Inh_Program = textBlockMap, Pass5.optionsLine_Inh_Program = optionsLine, Pass5.mainFile_Inh_Program = mainFile, Pass5.moduleHeader_Inh_Program = mkModuleHeader $ Pass1.moduleDecl_Syn_AG output1, Pass5.mainName_Inh_Program = mkMainName mainName $ Pass1.moduleDecl_Syn_AG output1}
          output5a  = Pass5a.wrap_Program        (Pass5a.sem_Program (Pass4.output_Syn_CGrammar output4)) Pass5a.Inh_Program { Pass5a.options_Inh_Program  = flags', Pass5a.textBlockMap_Inh_Program = textBlockMap }
          output6   = PrErr.wrap_Errors          (PrErr.sem_Errors                       errorsToReport) PrErr.Inh_Errors   {PrErr.options_Inh_Errors   = flags', PrErr.dups_Inh_Errors = [] }

          dump1    = GrammarDump.wrap_Grammar   (GrammarDump.sem_Grammar grammar1                     ) GrammarDump.Inh_Grammar
          dump2    = GrammarDump.wrap_Grammar   (GrammarDump.sem_Grammar grammar2                     ) GrammarDump.Inh_Grammar
          dump3    = CGrammarDump.wrap_CGrammar (CGrammarDump.sem_CGrammar grammar3                   ) CGrammarDump.Inh_CGrammar


          outputVisage = VisageDump.wrap_VisageGrammar (VisageDump.sem_VisageGrammar grammarV) VisageDump.Inh_VisageGrammar
          aterm        = VisageDump.aterm_Syn_VisageGrammar outputVisage

          parseErrorList   = map message2error (parseErrors)
          mainErrors       = toList ( Pass1.errors_Syn_AG       output1
                               Seq.>< Pass1a.errors_Syn_Grammar output1a
                               Seq.>< Pass2.errors_Syn_Grammar  output2
                               Seq.>< Pass2a.errors_Syn_Grammar output2a)
          furtherErrors    = if kennedyWarren flags' then []
                             else toList ( Pass3.errors_Syn_Grammar  output3
                                  Seq.>< Pass4.errors_Syn_CGrammar output4)

          errorList        = if null parseErrorList
                             then mainErrors
                                  ++ if null mainErrors || null (filter (PrErr.isError flags') mainErrors)
                                     then furtherErrors
                                     else []
                             else [head parseErrorList]

          fatalErrorList = filter (PrErr.isError flags') errorList

          allErrors = if wignore flags'
                      then fatalErrorList
                      else errorsToFront flags' errorList

          errorsToReport = take (wmaxerrs flags') allErrors

          errorsToStopOn = if werrors flags'
                            then errorList
                            else fatalErrorList

          blocks1                    = (Pass1.blocks_Syn_AG output1) {-SM `Map.unionWith (++)` (Pass3.blocks_Syn_Grammar output3)-}
          (pragmaBlocks, blocks2)    = Map.partitionWithKey (\(k, at) _->k==BlockPragma && at == Nothing) blocks1
          (importBlocks, textBlocks) = Map.partitionWithKey (\(k, at) _->k==BlockImport && at == Nothing) blocks2

          importBlocksTxt = vlist_sep "" . map addLocationPragma . concat . Map.elems $ importBlocks
          textBlocksDoc   = vlist_sep "" . map addLocationPragma . Map.findWithDefault [] (BlockOther, Nothing) $ textBlocks
          pragmaBlocksTxt = unlines . concat . map fst  . concat . Map.elems $ pragmaBlocks
          textBlockMap    = Map.map (vlist_sep "" . map addLocationPragma) . Map.filterWithKey (\(_, at) _ -> at /= Nothing) $ textBlocks

          outputfile = if null output then outputFile input else output

          addLocationPragma :: ([String], Pos) -> PP_Doc
          addLocationPragma (strs, p)
            | genLinePragmas flags'
                = "{-# LINE" >#< pp (show (line p)) >#< show (file p) >#< "#-}" >-< vlist (map pp strs) >-< "{-# LINE" >#< ppWithLineNr (pp.show.(+1)) >#< show outputfile >#< "#-}"
            | otherwise
                = vlist (map pp strs)

          optionsGHC = option (unbox flags') "-fglasgow-exts" ++ option (bangpats flags') "-XBangPatterns"
          option True s  = [s]
          option False _ = []
          optionsLine | null optionsGHC = ""
                      | otherwise       = "{-# OPTIONS_GHC " ++ unwords optionsGHC ++ " #-}"

          mainName = stripPath $ defaultModuleName input
          mainFile = defaultModuleName input

          nrOfErrorsToReport = length $ filter (PrErr.isError flags') errorsToReport
          nrOfWarningsToReport = length $ filter (not.(PrErr.isError flags')) errorsToReport
          totalNrOfErrors = length $ filter (PrErr.isError flags') allErrors
          totalNrOfWarnings = length $ filter (not.(PrErr.isError flags')) allErrors
          additionalErrors = totalNrOfErrors - nrOfErrorsToReport
          additionalWarnings = totalNrOfWarnings - nrOfWarningsToReport
          pluralS n = if n == 1 then "" else "s"


      (outAgi, ext) <-  --marcos
                     if genAspectAG flags'  
                     then parseAGI flags (searchPath flags) (agiFile input) 
                     else return (undefined, undefined)

      let ext' = case ext of
                        Nothing -> Nothing
                        Just e  -> Just (remAgi e)

          outAgi1   = Pass1.wrap_AG              (Pass1.sem_AG               outAgi ) Pass1.Inh_AG             {Pass1.options_Inh_AG       = flags'}
          agi       = Pass1.agi_Syn_AG           outAgi1
          aspectAG  = AspectAGDump.wrap_Grammar (AspectAGDump.sem_Grammar grammar2  ) AspectAGDump.Inh_Grammar { AspectAGDump.options_Inh_Grammar  = flags'
                                                                                                               , AspectAGDump.agi_Inh_Grammar      = agi
                                                                                                               , AspectAGDump.ext_Inh_Grammar      = ext' } --marcos


      putStr . formatErrors $ PrErr.pp_Syn_Errors output6

      if additionalErrors > 0
       then putStr $ "\nPlus " ++ show additionalErrors ++ " more error" ++ pluralS additionalErrors ++
                     if additionalWarnings > 0
                     then " and " ++ show additionalWarnings ++ " more warning" ++ pluralS additionalWarnings ++ ".\n"
                     else ".\n"
       else if additionalWarnings > 0
            then putStr $ "\nPlus " ++ show additionalWarnings ++ " more warning" ++ pluralS additionalWarnings ++ ".\n"
            else return ()

      if not (null fatalErrorList)
       then exitFailure
       else
        do
           if genvisage flags'
            then writeFile (outputfile++".visage") (writeATerm aterm)
            else return ()

           if genAttributeList flags'
            then writeAttributeList (outputfile++".attrs") (Pass1a.allAttributes_Syn_Grammar output1a)
            else return ()

           if sepSemMods flags'
            then do -- alternative module gen
                    if kennedyWarren flags'
                      then Pass4b.genIO_Syn_ExecutionPlan output4b
                      else Pass5.genIO_Syn_Program output5
                    if not (null errorsToStopOn) then exitFailure else return ()
            else do -- conventional module gen
                    let doc
                         | visitorsOutput flags'
                            = vlist [ pp_braces importBlocksTxt
                                    , pp_braces textBlocksDoc
                                    , vlist $ Pass4a.output_Syn_CGrammar output4a
                                    ]
                         -- marcos AspectAG gen
                         | genAspectAG flags'
                            = vlist [ AspectAGDump.pragmaAspectAG
                                    , pp optionsLine
                                    , pp pragmaBlocksTxt
                                    , pp $ take 70 ("-- UUAGC2AspectAG " ++ drop 50 banner ++ " (" ++ input) ++ ")"
                                    , pp $ if isNothing $ Pass1.moduleDecl_Syn_AG output1
                                           then moduleHeader flags' mainName
                                           else mkModuleHeader (Pass1.moduleDecl_Syn_AG output1) mainName "" "" False
                                    , pp importBlocksTxt
                                    , AspectAGDump.imp_Syn_Grammar aspectAG
                                    , pp "\n\n{-- AspectAG Code --}\n\n"
                                    , AspectAGDump.pp_Syn_Grammar aspectAG
                                    , textBlocksDoc
                                    , if dumpgrammar flags'
                                      then vlist [ pp "{- Dump of AGI"
                                                 , pp (show agi)
                                                 , pp "-}"
                                                 , pp "{- Dump of grammar with default rules"
                                                 , GrammarDump.pp_Syn_Grammar dump2
                                                 , pp "-}"
                                                 ]
                                      else empty]                         
                         | kennedyWarren flags'
                            = vlist [ pp optionsLine
                                    , pp $ "{-# LANGUAGE Rank2Types, GADTs, EmptyDataDecls #-}"
                                    , pp pragmaBlocksTxt
                                    , pp $ if isNothing $ Pass1.moduleDecl_Syn_AG output1
                                           then moduleHeader flags' mainName
                                           else mkModuleHeader (Pass1.moduleDecl_Syn_AG output1) mainName "" "" False
                                    , pp importBlocksTxt
                                    , pp $ "import Control.Monad.Identity (Identity)"
                                    , pp $ "import qualified Control.Monad.Identity"
                                    , textBlocksDoc
                                    --, pp $ "{-"
                                    --, Pass3a.depgraphs_Syn_Grammar output3a
                                    --, Pass3a.visitgraph_Syn_Grammar output3a
                                    --, pp $ "-}"
                                    , Pass4b.output_Syn_ExecutionPlan output4b
                                    , if dumpgrammar flags'
                                      then vlist [ pp "{- Dump of grammar with default rules"
                                                 , GrammarDump.pp_Syn_Grammar dump2
                                                 , pp "-}"
                                                 ]
                                      else empty]
                         | otherwise
                            = vlist [ vlist ( if not (ocaml flags')
                                              then [ pp optionsLine
                                                   , pp pragmaBlocksTxt
                                                   , pp $ take 70 ("-- UUAGC " ++ drop 50 banner ++ " (" ++ input) ++ ")"
                                                   , pp $ if isNothing $ Pass1.moduleDecl_Syn_AG output1
                                                          then moduleHeader flags' mainName
                                                          else mkModuleHeader (Pass1.moduleDecl_Syn_AG output1) mainName "" "" False
                                                   ]
                                              else []
                                            )
                                    , pp importBlocksTxt
                                    , textBlocksDoc
                                    , vlist $ if not (ocaml flags')
                                              then Pass5.output_Syn_Program  output5
                                              else Pass5a.output_Syn_Program output5a
                                    , if dumpgrammar flags'
                                      then vlist [ pp "{- Dump of grammar without default rules"
                                                 , GrammarDump.pp_Syn_Grammar dump1
                                                 , pp "-}"
                                                 , pp "{- Dump of grammar with default rules"
                                                 , GrammarDump.pp_Syn_Grammar dump2
                                                 , pp "-}"
                                                 ]
                                      else empty
                                    , if dumpcgrammar flags'
                                      then vlist [ pp "{- Dump of cgrammar"
                                                 , CGrammarDump.pp_Syn_CGrammar dump3
                                                 , pp "-}"
                                                 ]
                                      else empty
                                    ]

                    let docTxt = disp doc 50000 ""
                    writeFile outputfile docTxt
                    -- HACK: write statistics
                    let nAuto = Pass3.nAutoRules_Syn_Grammar output3
                        nExpl = Pass3.nExplicitRules_Syn_Grammar output3
                        line  = input ++ "," ++ show nAuto ++ "," ++ show nExpl ++ "\r\n"
                    case statsFile flags' of
                      Nothing   -> return ()
                      Just file -> appendFile file line
                    if not (null errorsToStopOn) then exitFailure else return ()



formatErrors :: PP_Doc -> String
formatErrors pp = disp pp 5000 ""


message2error :: Message Token Pos -> Error
message2error (Msg expect pos action) = ParserError pos (show expect) actionString
 where actionString
        =  case action
           of Insert s -> "inserting: " ++ show s

              Delete s -> "deleting: "  ++ show s

              Other ms -> ms

errorsToFront :: Options -> [Error] -> [Error]
errorsToFront flags mesgs = filter (PrErr.isError flags) mesgs ++ filter (not.(PrErr.isError flags)) mesgs


moduleHeader :: Options -> String -> String
moduleHeader flags input
 = case moduleName flags
   of Name nm -> genMod nm
      Default -> genMod (defaultModuleName input)
      NoName  -> ""
   where genMod x = "module " ++ x ++ " where"

inputFile :: String -> String
inputFile name
 = if ".ag" `isSuffixOf` name || ".lag" `isSuffixOf` name
   then name
   else name ++ ".ag"

--marcos
agiFile :: String -> String
agiFile name
 = if ".ag" `isSuffixOf` name || ".lag" `isSuffixOf` name
   then name ++ "i"
   else name ++ ".agi"

remAgi :: String -> String
remAgi name
 = takeWhile (/= '.') name


outputFile :: String -> String
outputFile name
 = defaultModuleName name ++ ".hs"

defaultModuleName :: String -> String
defaultModuleName name
 = if ".ag" `isSuffixOf` name
   then take (length name - 3) name
   else if ".lag" `isSuffixOf` name
   then take (length name - 4) name
   else name

stripPath :: String -> String
stripPath
  = reverse . takeWhile (\c -> c /= '/' && c /= '\\') . reverse

mkMainName :: String -> Maybe (String, String,String) -> String
mkMainName defaultName Nothing
  = defaultName
mkMainName _ (Just (name, _, _))
  = name

mkModuleHeader :: Maybe (String,String,String) -> String -> String -> String -> Bool -> String
mkModuleHeader Nothing defaultName suffix _ _
  = "module " ++ defaultName ++ suffix ++ " where"
mkModuleHeader (Just (name, exports, imports)) _ suffix addExports replaceExports
  = "module " ++ name ++ suffix ++ exp ++ " where\n" ++ imports ++ "\n"
  where
    exp = if null exports || (replaceExports && null addExports)
          then ""
          else if null addExports
               then "(" ++ exports ++ ")"
               else if replaceExports
                    then "(" ++ addExports ++ ")"
                    else "(" ++ exports ++ "," ++ addExports ++ ")"

reportDeps :: Options -> [String] -> IO ()
reportDeps flags files
  = do results <- mapM (depsAG flags (searchPath flags)) files
       let (fs, mesgs) = foldr combine ([],[]) results
       let errs = take (min 1 (wmaxerrs flags)) (map message2error mesgs)
       let ppErrs = PrErr.wrap_Errors (PrErr.sem_Errors errs) PrErr.Inh_Errors {PrErr.options_Inh_Errors = flags, PrErr.dups_Inh_Errors = []}
       if null errs
        then mapM_ putStrLn fs
        else do putStr . formatErrors $ PrErr.pp_Syn_Errors ppErrs
                exitFailure
  where
    combine :: ([a],[b]) -> ([a], [b]) -> ([a], [b])
    combine (fs, mesgs) (fsr, mesgsr)
      = (fs ++ fsr, mesgs ++ mesgsr)


writeAttributeList :: String -> AttrMap -> IO ()
writeAttributeList file mp
  = writeFile file s
  where
    s = show $ map (\(x,y) -> (show x, y)) $ Map.toList $ Map.map (map (\(x,y) -> (show x, y)) . Map.toList . Map.map (map (\(x,y) -> (show x, show y)) . Set.toList)) $ mp

readIrrefutableMap :: Options -> IO AttrMap
readIrrefutableMap flags
  = case forceIrrefutables flags of
      Just file -> do s <- readFile file
                      seq (length s) (return ())
                      let lists :: [(String,[(String,[(String, String)])])]
                          lists = read s
                      return $ Map.fromList [ (identifier n, Map.fromList [(identifier c, Set.fromList [ (identifier fld, identifier attr) | (fld,attr) <- ss ]) | (c,ss) <- cs ]) | (n,cs) <- lists ]
      Nothing   -> return Map.empty


