{-# LANGUAGE OverloadedStrings #-}
module Pipeline.Generate where

import Control.Monad.Except (forM_, liftIO)
import qualified Data.Graph as Graph
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Text.Lazy as LazyText
import qualified Data.Text.Lazy.Encoding as LazyText
import qualified Data.Text.Lazy.IO as LazyText
import qualified Data.Tree as Tree
import Elm.Utils ((|>))
import qualified Elm.Compiler.Module as Module
import qualified Elm.Docs as Docs
import System.Directory ( createDirectoryIfMissing )
import System.FilePath ( dropFileName )
import System.IO ( IOMode(WriteMode) )
import qualified Text.Blaze as Blaze
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import qualified Text.Blaze.Renderer.Text as Blaze

import qualified BuildManager as BM
import qualified Path
import TheMasterPlan ( CanonicalModule(CanonicalModule), Location )
import qualified Utils.File as File


-- GENERATE DOCS

docs :: [Docs.Documentation] -> FilePath -> BM.Task ()
docs docsList path =
  Docs.prettyJson docsList
    |> LazyText.decodeUtf8
    |> LazyText.replace "\\u003e" ">"
    |> LazyText.writeFile path
    |> liftIO


-- GENERATE ELM STUFF

generate
    :: BM.Config
    -> Map.Map CanonicalModule [CanonicalModule]
    -> Map.Map CanonicalModule Location
    -> [CanonicalModule]
    -> BM.Task ()

generate _config _dependencies _natives [] =
  return ()

generate config dependencies natives rootModules =
  do  let objectFiles =
            setupNodes (BM._artifactDirectory config) dependencies natives
              |> getReachableObjectFiles rootModules

      let outputFile = BM.outputFilePath config
      liftIO (createDirectoryIfMissing True (dropFileName outputFile))

      case BM._output config of
        BM.Html outputFile ->
            liftIO $
              do  js <- mapM File.readTextUtf8 objectFiles
                  let (Just (CanonicalModule _ moduleName)) = Maybe.listToMaybe rootModules
                  let outputText = html (Text.concat (plainHeader:js)) moduleName
                  LazyText.writeFile outputFile outputText

        BM.JS outputFile ->
          liftIO $
          File.withFileUtf8 outputFile WriteMode $ \handle ->
              do  Text.hPutStrLn handle header
                  forM_ objectFiles $ \jsFile ->
                      Text.hPutStrLn handle =<< File.readTextUtf8 jsFile
                  Text.hPutStrLn handle bottom

      liftIO (putStrLn ("Successfully generated " ++ outputFile))


plainHeader :: Text.Text
plainHeader =
    "var Elm = Elm || { Native: {} };"

header :: Text.Text
header =
    "(function() {\n\
    \var Elm = Elm || { Native: {} };"

bottom :: Text.Text
bottom =
    "\nif (typeof define === 'function' && define.amd) {\n\
    \  define([], function() {\n\
    \    return Elm;\n\
    \  });\n\
    \} else if (typeof module === 'object') {\n\
    \  module.exports = Elm;\n\
    \} else {\n\
    \  if (typeof this.Elm === 'undefined') {\n\
    \    this.Elm = Elm;\n\
    \  } else {\n\
    \    throw new Error('This page is trying to import multiple compiled Elm programs using the same `Elm` global object, which would cause conflicts. This can be resolved by using a module loader like RequireJS to import the compiled Elm programs into different objects.');\n\
    \  }\n\
    \}\n\
    \}).call(this);"


setupNodes
    :: FilePath
    -> Map.Map CanonicalModule [CanonicalModule]
    -> Map.Map CanonicalModule Location
    -> [(FilePath, CanonicalModule, [CanonicalModule])]
setupNodes cachePath dependencies natives =
    let nativeNodes =
            Map.toList natives
              |> map (\(name, loc) -> (Path.toSource loc, name, []))

        dependencyNodes =
            Map.toList dependencies
              |> map (\(name, deps) -> (Path.toObjectFile cachePath name, name, deps))
    in
        nativeNodes ++ dependencyNodes


getReachableObjectFiles
    :: [CanonicalModule]
    -> [(FilePath, CanonicalModule, [CanonicalModule])]
    -> [FilePath]
getReachableObjectFiles moduleNames nodes =
    let (dependencyGraph, vertexToKey, keyToVertex) =
            Graph.graphFromEdges nodes

        reachableSet =
            Maybe.mapMaybe keyToVertex moduleNames
              |> Graph.dfs dependencyGraph
              |> concatMap Tree.flatten
              |> Set.fromList
    in
        Graph.topSort dependencyGraph
          |> filter (\vtx -> Set.member vtx reachableSet)
          |> reverse
          |> map vertexToKey
          |> map (\(path, _, _) -> path)


-- GENERATE HTML

html :: Text.Text -> Module.Name -> LazyText.Text
html generatedJavaScript moduleName =
  Blaze.renderMarkup $
    H.docTypeHtml $ do
      H.head $ do
        H.meta ! A.charset "UTF-8"
        H.title (H.toHtml (Module.nameToString moduleName))
        H.style $ Blaze.preEscapedToMarkup
            ("html,head,body { padding:0; margin:0; }\n\
             \body { font-family: calibri, helvetica, arial, sans-serif; }" :: Text.Text)
        H.script ! A.type_ "text/javascript" $
            Blaze.preEscapedToMarkup generatedJavaScript
      H.body $ do
        H.script ! A.type_ "text/javascript" $
            Blaze.preEscapedToMarkup ("Elm.fullscreen(Elm." ++ Module.nameToString moduleName ++ ")")
