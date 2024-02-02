{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module Maven.PluginSpec (spec) where

import Data.Text (Text)
import Data.Tree (Tree (..))
import Strategy.Maven.Plugin (Artifact (..), Edge (..), PluginOutput (..), textArtifactToPluginOutput, ReactorOutput (..), parseReactorOutput, parsePluginOutput)
import Strategy.Maven.PluginTree (TextArtifact (..), parseTextArtifact)
import Test.Effect (expectationFailure', it', shouldBe', shouldContain', shouldMatchList')
import Test.Hspec (Spec, describe)
import Text.Megaparsec (parseMaybe)
import Text.RawString.QQ (r)
import Data.Aeson (decode)
import Data.Text.Encoding
import Data.ByteString.Lazy (fromStrict)
import Strategy.Maven.PluginStrategy (buildGraph)
import Control.Carrier.Lift
import Path
import Graphing (vertexList)
import Control.Effect.Path (withSystemTempDir)
import Path.IO (copyFile, createDirIfMissing)

spec :: Spec
spec = do
  textArtifactConversionSpec

singleTextArtifact :: TextArtifact
singleTextArtifact =
  TextArtifact
    { artifactText = "org.clojure:clojure:1.12.0-master-SNAPSHOT"
    , groupId = "org.clojure"
    , artifactId = "clojure"
    , textArtifactVersion = "1.12.0-master-SNAPSHOT"
    , scopes = ["test"]
    , isDirect = True
    , isOptional = False
    }

complexTextArtifact :: Tree TextArtifact
complexTextArtifact =
  Node
    TextArtifact
      { artifactText = "org.clojure:test.generative:1.0.0"
      , groupId = "org.clojure"
      , artifactId = "test.generative"
      , textArtifactVersion = "1.0.0"
      , scopes = ["test"]
      , isDirect = True
      , isOptional = False
      }
    [ Node
        TextArtifact
          { artifactText = "org.fake:fake-pkg:1.0.0"
          , groupId = "org.fake"
          , artifactId = "fake-pkg"
          , textArtifactVersion = "1.0.0"
          , scopes = ["compile"]
          , isDirect = False
          , isOptional = True
          }
        []
    , Node
        TextArtifact
          { artifactText = "org.foo:bar:1.0.0"
          , groupId = "org.foo"
          , artifactId = "bar"
          , textArtifactVersion = "1.0.0"
          , isDirect = False
          , scopes = ["compile"]
          , isOptional = False
          }
        [ Node
            TextArtifact
              { artifactText = "org.baz:buzz:1.0.0"
              , groupId = "org.baz"
              , artifactId = "buzz"
              , textArtifactVersion = "1.0.0"
              , isDirect = False
              , scopes = ["test"]
              , isOptional = False
              }
            []
        ]
    , Node
        TextArtifact
          { artifactText = "org.clojure:data.generators:1.0.0"
          , groupId = "org.clojure"
          , artifactId = "data.generators"
          , textArtifactVersion = "1.0.0"
          , isDirect = False
          , scopes = ["test"]
          , isOptional = False
          }
        []
    ]

complexPluginOutputArtifacts :: PluginOutput
complexPluginOutputArtifacts =
  PluginOutput
    { outArtifacts =
        [ Artifact
            { artifactNumericId = 0
            , artifactGroupId = "org.clojure"
            , artifactArtifactId = "data.generators"
            , artifactVersion = "1.0.0"
            , artifactScopes = ["test"]
            , artifactOptional = False
            , artifactIsDirect = False
            }
        , Artifact
            { artifactNumericId = 1
            , artifactGroupId = "org.baz"
            , artifactArtifactId = "buzz"
            , artifactVersion = "1.0.0"
            , artifactScopes = ["test"]
            , artifactOptional = False
            , artifactIsDirect = False
            }
        , Artifact
            { artifactNumericId = 2
            , artifactGroupId = "org.foo"
            , artifactArtifactId = "bar"
            , artifactVersion = "1.0.0"
            , artifactScopes = ["compile"]
            , artifactOptional = False
            , artifactIsDirect = False
            }
        , Artifact
            { artifactNumericId = 3
            , artifactGroupId = "org.fake"
            , artifactArtifactId = "fake-pkg"
            , artifactVersion = "1.0.0"
            , artifactScopes = ["compile"]
            , artifactOptional = True
            , artifactIsDirect = False
            }
        , Artifact
            { artifactNumericId = 4
            , artifactGroupId = "org.clojure"
            , artifactArtifactId = "test.generative"
            , artifactVersion = "1.0.0"
            , artifactScopes = ["test"]
            , artifactOptional = False
            , artifactIsDirect = True
            }
        ]
    , outEdges =
        [ Edge 2 1
        , Edge 4 3
        , Edge 4 2
        , Edge 4 0
        ]
    }


textArtifactConversionSpec :: Spec
textArtifactConversionSpec =
  describe "Maven text artifact -> PluginOutput conversion" $ do
    it' "Converts a single TextArtifact correctly" $ do
      pluginOutput <- textArtifactToPluginOutput (Node singleTextArtifact [])
      pluginOutput
        `shouldBe'` PluginOutput
          { outArtifacts = [simpleArtifact]
          , outEdges = []
          }

    it' "Converts a more complex TextArtifact correctly" $ do
      PluginOutput{outArtifacts = resArts, outEdges = resEdges} <- textArtifactToPluginOutput complexTextArtifact
      resArts `shouldMatchList'` (outArtifacts complexPluginOutputArtifacts)
      resEdges `shouldMatchList'` (outEdges complexPluginOutputArtifacts)

    it' "should correctly include dependency with multiple scopes" $ do
      let maybeArtifactTree = mkTreeTextArtifact depWithMultipleScopes
      case maybeArtifactTree of
        Nothing -> expectationFailure' "could not parse raw tree output!"
        Just tree' -> do
          PluginOutput{outArtifacts = resArts} <- textArtifactToPluginOutput tree'
          resArts `shouldContain'` [kafkaClientCompile]
          resArts `shouldContain'` [kafkaClientTest]

    it' "works with text" $ do
      let maybeArtifactTree = mkTreeTextArtifact fdn98BoschDepGraphOutput
      case maybeArtifactTree of
        Nothing -> expectationFailure' "could not parse raw tree output!"
        Just tree' -> do
          pl@PluginOutput{outArtifacts = resArts} <- textArtifactToPluginOutput tree'
          length (resArts) `shouldBe'` 855
          let reactorOutput = decode (fromStrict $ encodeUtf8 fdn98BoschReactorOutput) :: Maybe ReactorOutput
          case reactorOutput of
            Nothing -> expectationFailure' "could not parse raw reactor output!"
            Just reactorOutput' -> do
              length (reactorArtifacts reactorOutput') `shouldBe'` 7
              let res = buildGraph reactorOutput' pl
              sendIO $ length (Graphing.vertexList res) `shouldBe'` 177

    it' "works with files" $ do
      withSystemTempDir "fossa" $ \tmpDir -> do
        createDirIfMissing True (tmpDir </> $(mkRelDir "target"))
        copyFile $(mkRelFile "test/Maven/testdata/dependency-graph.txt") (tmpDir </>  $(mkRelFile "target/dependency-graph.txt"))
        copyFile $(mkRelFile "test/Maven/testdata/fossa-reactor-graph.json") (tmpDir </> $(mkRelFile "fossa-reactor-graph.json"))
        reactorOutput <- parseReactorOutput tmpDir
        length (reactorArtifacts reactorOutput) `shouldBe'` 7
        pluginOutput <- parsePluginOutput tmpDir
        length (outArtifacts pluginOutput) `shouldBe'` 855
        let res = buildGraph reactorOutput pluginOutput
        sendIO $ length (Graphing.vertexList res) `shouldBe'` 177



simpleArtifact :: Artifact
simpleArtifact =
  Artifact
    { artifactNumericId = 0
    , artifactGroupId = "org.clojure"
    , artifactArtifactId = "clojure"
    , artifactVersion = "1.12.0-master-SNAPSHOT"
    , artifactOptional = False
    , artifactScopes = ["test"]
    , artifactIsDirect = True
    }

mkTreeTextArtifact :: Text -> Maybe (Tree TextArtifact)
mkTreeTextArtifact = parseMaybe parseTextArtifact

depWithMultipleScopes :: Text
depWithMultipleScopes =
  [r|com.mycompany.app:my-app:1.0-SNAPSHOT:compile
+- junit:junit:4.11:test
|  \- org.hamcrest:hamcrest-core:1.3:test
+- org.apache.kafka:kafka-clients:3.0.2:compile
|  +- com.github.luben:zstd-jni:1.5.0-2:runtime
|  +- org.lz4:lz4-java:1.7.1:runtime
|  +- org.xerial.snappy:snappy-java:1.1.8.1:runtime
|  \- org.slf4j:slf4j-api:1.7.30:runtime
+- org.apache.kafka:kafka-clients:3.0.2:test
\- joda-time:joda-time:2.9.2:compile|]

kafkaClientCompile :: Artifact
kafkaClientCompile = Artifact 6 "org.apache.kafka" "kafka-clients" "3.0.2" ["compile"] False False

kafkaClientTest :: Artifact
kafkaClientTest = kafkaClientCompile{artifactNumericId = 1, artifactScopes = ["test"]}

fdn98BoschReactorOutput:: Text
fdn98BoschReactorOutput =
  [r|{
  "graphName" : "G",
  "artifacts" : [ {
    "id" : "bike.cobi:cobi-bhu",
    "numericId" : 1,
    "artifactId" : "cobi-bhu"
  }, {
    "id" : "bike.cobi:jacoco",
    "numericId" : 2,
    "artifactId" : "jacoco"
  }, {
    "id" : "bike.cobi:cobi-neural-network-dl4j",
    "numericId" : 3,
    "artifactId" : "cobi-neural-network-dl4j"
  }, {
    "id" : "bike.cobi:cobi-web",
    "numericId" : 4,
    "artifactId" : "cobi-web"
  }, {
    "id" : "bike.cobi:cobi-core",
    "numericId" : 5,
    "artifactId" : "cobi-core"
  }, {
    "id" : "bike.cobi:cobi-neural-network-base",
    "numericId" : 6,
    "artifactId" : "cobi-neural-network-base"
  }, {
    "id" : "bike.cobi:cobi-project",
    "numericId" : 7,
    "artifactId" : "cobi-project"
  } ],
  "dependencies" : [ {
    "from" : "bike.cobi:cobi-bhu",
    "to" : "bike.cobi:jacoco",
    "numericFrom" : 0,
    "numericTo" : 1,
    "resolution" : "PARENT"
  }, {
    "from" : "bike.cobi:cobi-neural-network-dl4j",
    "to" : "bike.cobi:cobi-web",
    "numericFrom" : 2,
    "numericTo" : 3,
    "resolution" : "PARENT"
  }, {
    "from" : "bike.cobi:cobi-core",
    "to" : "bike.cobi:cobi-bhu",
    "numericFrom" : 4,
    "numericTo" : 0,
    "resolution" : "PARENT"
  }, {
    "from" : "bike.cobi:cobi-neural-network-base",
    "to" : "bike.cobi:cobi-core",
    "numericFrom" : 5,
    "numericTo" : 4,
    "resolution" : "PARENT"
  }, {
    "from" : "bike.cobi:cobi-neural-network-base",
    "to" : "bike.cobi:cobi-neural-network-dl4j",
    "numericFrom" : 5,
    "numericTo" : 2,
    "resolution" : "PARENT"
  }, {
    "from" : "bike.cobi:cobi-project",
    "to" : "bike.cobi:cobi-neural-network-base",
    "numericFrom" : 6,
    "numericTo" : 5,
    "resolution" : "PARENT"
  } ]
}|]

fdn98BoschDepGraphOutput :: Text
fdn98BoschDepGraphOutput =
  [r|bike.cobi:jacoco:5.0.0:compile
+- bike.cobi:cobi-core:5.0.0:compile
|  +- bike.cobi:cobi-neural-network-base:5.0.0:compile
|  |  +- org.apache.commons:commons-lang3:3.13.0:compile
|  |  +- commons-net:commons-net:3.9.0:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  \- commons-io:commons-io:2.7:compile
|  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
+- bike.cobi:cobi-neural-network-base:5.0.0:compile
|  +- org.apache.commons:commons-lang3:3.13.0:compile
|  +- commons-net:commons-net:3.9.0:compile
|  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  \- commons-io:commons-io:2.7:compile
|  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
+- bike.cobi:cobi-neural-network-dl4j:5.0.0:compile
|  +- bike.cobi:cobi-neural-network-base:5.0.0:compile
|  |  +- org.apache.commons:commons-lang3:3.13.0:compile
|  |  +- commons-net:commons-net:3.9.0:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  +- org.nd4j:nd4j-native:1.0.0-M2.1:compile
|  |  +- org.nd4j:nd4j-native:1.0.0-M2.1:compile
|  |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  +- org.nd4j:nd4j-api:1.0.0-M2.1:compile
|  |  |  +- com.jakewharton.byteunits:byteunits:0.9.1:compile
|  |  |  +- org.apache.commons:commons-math3:3.5:compile
|  |  |  +- org.apache.commons:commons-collections4:4.1:compile
|  |  |  +- com.google.flatbuffers:flatbuffers-java:1.12.0:compile
|  |  |  +- org.nd4j:protobuf:1.0.0-M2.1:compile
|  |  |  +- com.github.oshi:oshi-core:3.4.2:compile
|  |  |  |  +- net.java.dev.jna:jna-platform:4.3.0:compile
|  |  |  |  |  \- net.java.dev.jna:jna:4.3.0:compile
|  |  |  |  \- org.threeten:threetenbp:1.3.3:compile
|  |  |  +- net.ericaro:neoitertools:1.0.0:compile
|  |  |  \- org.nd4j:nd4j-common:1.0.0-M2.1:compile
|  |  |     +- org.nd4j:guava:1.0.0-M2.1:compile
|  |  |     +- org.apache.commons:commons-compress:1.21:compile
|  |  |     \- commons-codec:commons-codec:1.16.0:compile
|  |  +- org.nd4j:nd4j-native-api:1.0.0-M2.1:compile
|  |  +- org.nd4j:nd4j-native-preset:1.0.0-M2.1:compile
|  |  |  +- org.nd4j:nd4j-presets-common:1.0.0-M2.1:compile
|  |  |  +- org.nd4j:nd4j-native-preset:1.0.0-M2.1:compile
|  |  |  +- org.bytedeco:openblas:0.3.19-1.5.7:compile
|  |  |  \- org.bytedeco:openblas:0.3.19-1.5.7:compile
|  |  \- org.bytedeco:javacpp:1.5.7:compile
|  +- org.nd4j:nd4j-native:1.0.0-M2.1:compile
|  +- org.deeplearning4j:deeplearning4j-modelimport:1.0.0-M2.1:compile
|  |  +- org.slf4j:slf4j-api:1.7.36:compile
|  |  +- org.deeplearning4j:deeplearning4j-nn:1.0.0-M2.1:compile
|  |  |  +- org.deeplearning4j:deeplearning4j-utility-iterators:1.0.0-M2.1:compile
|  |  |  +- commons-io:commons-io:2.7:compile
|  |  |  +- it.unimi.dsi:fastutil:6.5.7:compile
|  |  |  \- org.deeplearning4j:resources:1.0.0-M2.1:compile
|  |  +- org.nd4j:jackson:1.0.0-M2.1:compile
|  |  \- org.bytedeco:hdf5-platform:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:javacpp-platform:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |     |  \- org.bytedeco:javacpp:1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |     \- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  +- com.google.code.gson:gson:2.8.9:compile
|  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  \- commons-io:commons-io:2.7:compile
|  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
+- bike.cobi:cobi-web:5.0.0:compile
|  +- bike.cobi:cobi-core:5.0.0:compile
|  |  +- bike.cobi:cobi-neural-network-base:5.0.0:compile
|  |  |  +- org.apache.commons:commons-lang3:3.13.0:compile
|  |  |  +- commons-net:commons-net:3.9.0:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  +- bike.cobi:cobi-core:5.0.0:test
|  +- bike.cobi:cobi-neural-network-dl4j:5.0.0:compile
|  |  +- bike.cobi:cobi-neural-network-base:5.0.0:compile
|  |  |  +- org.apache.commons:commons-lang3:3.13.0:compile
|  |  |  +- commons-net:commons-net:3.9.0:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  |  +- org.nd4j:nd4j-native:1.0.0-M2.1:compile
|  |  |  +- org.nd4j:nd4j-native:1.0.0-M2.1:compile
|  |  |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |  +- org.nd4j:nd4j-api:1.0.0-M2.1:compile
|  |  |  |  +- com.jakewharton.byteunits:byteunits:0.9.1:compile
|  |  |  |  +- org.apache.commons:commons-math3:3.5:compile
|  |  |  |  +- org.apache.commons:commons-collections4:4.1:compile
|  |  |  |  +- com.google.flatbuffers:flatbuffers-java:1.12.0:compile
|  |  |  |  +- org.nd4j:protobuf:1.0.0-M2.1:compile
|  |  |  |  +- com.github.oshi:oshi-core:3.4.2:compile
|  |  |  |  |  +- net.java.dev.jna:jna-platform:4.3.0:compile
|  |  |  |  |  |  \- net.java.dev.jna:jna:4.3.0:compile
|  |  |  |  |  \- org.threeten:threetenbp:1.3.3:compile
|  |  |  |  +- net.ericaro:neoitertools:1.0.0:compile
|  |  |  |  \- org.nd4j:nd4j-common:1.0.0-M2.1:compile
|  |  |  |     +- org.nd4j:guava:1.0.0-M2.1:compile
|  |  |  |     +- org.apache.commons:commons-compress:1.21:compile
|  |  |  |     \- commons-codec:commons-codec:1.16.0:compile
|  |  |  +- org.nd4j:nd4j-native-api:1.0.0-M2.1:compile
|  |  |  +- org.nd4j:nd4j-native-preset:1.0.0-M2.1:compile
|  |  |  |  +- org.nd4j:nd4j-presets-common:1.0.0-M2.1:compile
|  |  |  |  +- org.nd4j:nd4j-native-preset:1.0.0-M2.1:compile
|  |  |  |  +- org.bytedeco:openblas:0.3.19-1.5.7:compile
|  |  |  |  \- org.bytedeco:openblas:0.3.19-1.5.7:compile
|  |  |  \- org.bytedeco:javacpp:1.5.7:compile
|  |  +- org.nd4j:nd4j-native:1.0.0-M2.1:compile
|  |  +- org.deeplearning4j:deeplearning4j-modelimport:1.0.0-M2.1:compile
|  |  |  +- org.slf4j:slf4j-api:1.7.36:compile
|  |  |  +- org.deeplearning4j:deeplearning4j-nn:1.0.0-M2.1:compile
|  |  |  |  +- org.deeplearning4j:deeplearning4j-utility-iterators:1.0.0-M2.1:compile
|  |  |  |  +- commons-io:commons-io:2.7:compile
|  |  |  |  +- it.unimi.dsi:fastutil:6.5.7:compile
|  |  |  |  \- org.deeplearning4j:resources:1.0.0-M2.1:compile
|  |  |  +- org.nd4j:jackson:1.0.0-M2.1:compile
|  |  |  \- org.bytedeco:hdf5-platform:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:javacpp-platform:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  +- org.bytedeco:javacpp:1.5.7:compile
|  |  |     |  \- org.bytedeco:javacpp:1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     +- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  |     \- org.bytedeco:hdf5:1.12.1-1.5.7:compile
|  |  +- com.google.code.gson:gson:2.8.9:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  +- com.bosch.ebike.graphhopper:graphhopper-web:5.5.5:compile
|  +- io.prometheus:simpleclient:0.14.1:compile
|  |  +- io.prometheus:simpleclient_tracer_otel:0.14.1:compile
|  |  |  \- io.prometheus:simpleclient_tracer_common:0.14.1:compile
|  |  \- io.prometheus:simpleclient_tracer_otel_agent:0.14.1:compile
|  +- io.prometheus:simpleclient_servlet:0.14.1:compile
|  |  +- io.prometheus:simpleclient_common:0.14.1:compile
|  |  \- io.prometheus:simpleclient_servlet_common:0.14.1:compile
|  +- io.prometheus:simpleclient_dropwizard:0.14.1:compile
|  |  \- io.dropwizard.metrics:metrics-core:4.2.21:compile/test
|  +- io.dropwizard:dropwizard-json-logging:2.1.9:compile
|  |  +- io.dropwizard:dropwizard-jackson:2.1.9:compile
|  |  |  +- com.google.guava:guava:32.1.3-jre:compile
|  |  |  |  +- com.google.guava:failureaccess:1.0.1:compile/test
|  |  |  |  +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |  |  |  +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |  |  |  +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |  |  |  \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |  |  +- com.github.ben-manes.caffeine:caffeine:2.9.3:compile/test
|  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.13.5:compile/test
|  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-jdk8:2.13.5:compile/test
|  |  |  +- com.fasterxml.jackson.module:jackson-module-parameter-names:2.13.5:compile/test
|  |  |  +- com.fasterxml.jackson.module:jackson-module-blackbird:2.13.5:compile/test
|  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-joda:2.13.5:compile
|  |  |  |  \- joda-time:joda-time:2.12.5:compile/test
|  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-guava:2.13.5:compile/test
|  |  |  \- io.dropwizard:dropwizard-util:2.1.9:compile/test
|  |  |     \- com.google.guava:guava:32.1.3-jre:compile
|  |  |        +- com.google.guava:failureaccess:1.0.1:compile/test
|  |  |        +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |  |        +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |  |        +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |  |        \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |  +- io.dropwizard:dropwizard-logging:2.1.9:compile
|  |  |  +- io.dropwizard.metrics:metrics-logback:4.2.21:compile/test
|  |  |  +- org.slf4j:jul-to-slf4j:1.7.36:compile/test
|  |  |  +- io.dropwizard.logback:logback-throttling-appender:1.1.10:compile/test
|  |  |  +- org.slf4j:log4j-over-slf4j:1.7.36:runtime/test
|  |  |  +- org.slf4j:jcl-over-slf4j:1.7.36:runtime/test
|  |  |  +- org.eclipse.jetty:jetty-util:9.4.53.v20231009:compile/test
|  |  |  \- ch.qos.logback:logback-core:1.2.12:compile/test
|  |  +- io.dropwizard:dropwizard-request-logging:2.1.9:compile/test
|  |  |  \- ch.qos.logback:logback-access:1.2.12:compile/test
|  |  +- io.dropwizard:dropwizard-validation:2.1.9:compile
|  |  |  +- com.fasterxml:classmate:1.6.0:compile/test
|  |  |  +- org.hibernate.validator:hibernate-validator:6.2.5.Final:compile
|  |  |  |  \- org.jboss.logging:jboss-logging:3.4.1.Final:compile/test
|  |  |  \- org.glassfish:jakarta.el:3.0.4:runtime/test
|  |  +- ch.qos.logback:logback-access:1.2.12:compile/test
|  |  +- ch.qos.logback:logback-classic:1.2.12:compile/test
|  |  +- ch.qos.logback:logback-core:1.2.12:compile/test
|  |  +- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  +- com.google.code.findbugs:jsr305:3.0.2:compile/test
|  |  +- jakarta.servlet:jakarta.servlet-api:4.0.4:compile/test
|  |  +- jakarta.validation:jakarta.validation-api:2.0.2:compile/test
|  |  +- org.eclipse.jetty:jetty-http:9.4.53.v20231009:compile
|  |  |  \- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |  +- org.eclipse.jetty:jetty-server:9.4.53.v20231009:compile/test
|  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  +- io.dropwizard:dropwizard-testing:2.1.9:test
|  |  +- io.dropwizard:dropwizard-configuration:2.1.9:test
|  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-yaml:2.13.5:test
|  |  |  |  \- org.yaml:snakeyaml:1.32:test
|  |  |  \- org.apache.commons:commons-text:1.10.0:test
|  |  +- io.dropwizard:dropwizard-core:2.1.9:test
|  |  |  +- io.dropwizard:dropwizard-metrics:2.1.9:test
|  |  |  +- io.dropwizard:dropwizard-health:2.1.9:test
|  |  |  +- io.dropwizard.metrics:metrics-jetty9:4.2.21:test
|  |  |  +- io.dropwizard.metrics:metrics-jvm:4.2.21:test
|  |  |  +- io.dropwizard.metrics:metrics-jmx:4.2.21:test
|  |  |  +- io.dropwizard.metrics:metrics-servlets:4.2.21:test
|  |  |  |  +- io.dropwizard.metrics:metrics-json:4.2.21:test
|  |  |  |  \- com.helger:profiler:1.1.1:test
|  |  |  +- org.eclipse.jetty:jetty-security:9.4.53.v20231009:test
|  |  |  +- org.eclipse.jetty:jetty-servlet:9.4.53.v20231009:test
|  |  |  |  \- org.eclipse.jetty:jetty-util-ajax:9.4.53.v20231009:test
|  |  |  +- org.eclipse.jetty.toolchain.setuid:jetty-setuid-java:1.0.4:test
|  |  |  +- jakarta.inject:jakarta.inject-api:1.0.5:test
|  |  |  +- org.glassfish.jersey.ext:jersey-bean-validation:2.40:test
|  |  |  +- io.dropwizard:dropwizard-util:2.1.9:compile/test
|  |  |  |  \- com.google.guava:guava:32.1.3-jre:compile
|  |  |  |     +- com.google.guava:failureaccess:1.0.1:compile/test
|  |  |  |     +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |  |  |     +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |  |  |     +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |  |  |     \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |  |  +- io.dropwizard:dropwizard-jackson:2.1.9:compile
|  |  |  |  +- com.google.guava:guava:32.1.3-jre:compile
|  |  |  |  |  +- com.google.guava:failureaccess:1.0.1:compile/test
|  |  |  |  |  +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |  |  |  |  +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |  |  |  |  +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |  |  |  |  \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |  |  |  +- com.github.ben-manes.caffeine:caffeine:2.9.3:compile/test
|  |  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.13.5:compile/test
|  |  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-jdk8:2.13.5:compile/test
|  |  |  |  +- com.fasterxml.jackson.module:jackson-module-parameter-names:2.13.5:compile/test
|  |  |  |  +- com.fasterxml.jackson.module:jackson-module-blackbird:2.13.5:compile/test
|  |  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-joda:2.13.5:compile
|  |  |  |  |  \- joda-time:joda-time:2.12.5:compile/test
|  |  |  |  +- com.fasterxml.jackson.datatype:jackson-datatype-guava:2.13.5:compile/test
|  |  |  |  \- io.dropwizard:dropwizard-util:2.1.9:compile/test
|  |  |  |     \- com.google.guava:guava:32.1.3-jre:compile
|  |  |  |        +- com.google.guava:failureaccess:1.0.1:compile/test
|  |  |  |        +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |  |  |        +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |  |  |        +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |  |  |        \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |  |  +- io.dropwizard:dropwizard-validation:2.1.9:compile
|  |  |  |  +- com.fasterxml:classmate:1.6.0:compile/test
|  |  |  |  +- org.hibernate.validator:hibernate-validator:6.2.5.Final:compile
|  |  |  |  |  \- org.jboss.logging:jboss-logging:3.4.1.Final:compile/test
|  |  |  |  \- org.glassfish:jakarta.el:3.0.4:runtime/test
|  |  |  +- io.dropwizard:dropwizard-configuration:2.1.9:test
|  |  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-yaml:2.13.5:test
|  |  |  |  |  \- org.yaml:snakeyaml:1.32:test
|  |  |  |  \- org.apache.commons:commons-text:1.10.0:test
|  |  |  +- io.dropwizard:dropwizard-logging:2.1.9:compile
|  |  |  |  +- io.dropwizard.metrics:metrics-logback:4.2.21:compile/test
|  |  |  |  +- org.slf4j:jul-to-slf4j:1.7.36:compile/test
|  |  |  |  +- io.dropwizard.logback:logback-throttling-appender:1.1.10:compile/test
|  |  |  |  +- org.slf4j:log4j-over-slf4j:1.7.36:runtime/test
|  |  |  |  +- org.slf4j:jcl-over-slf4j:1.7.36:runtime/test
|  |  |  |  +- org.eclipse.jetty:jetty-util:9.4.53.v20231009:compile/test
|  |  |  |  \- ch.qos.logback:logback-core:1.2.12:compile/test
|  |  |  +- io.dropwizard:dropwizard-jersey:2.1.9:test
|  |  |  |  +- org.glassfish.jersey.ext:jersey-metainf-services:2.40:test
|  |  |  |  +- org.glassfish.jersey.inject:jersey-hk2:2.40:test
|  |  |  |  |  \- org.glassfish.hk2:hk2-locator:2.6.1:test
|  |  |  |  +- org.javassist:javassist:3.29.2-GA:test
|  |  |  |  +- io.dropwizard.metrics:metrics-jersey2:4.2.21:test
|  |  |  |  +- jakarta.annotation:jakarta.annotation-api:1.3.5:test
|  |  |  |  +- joda-time:joda-time:2.12.5:compile/test
|  |  |  |  +- org.glassfish.hk2:hk2-api:2.6.1:test
|  |  |  |  |  +- org.glassfish.hk2:hk2-utils:2.6.1:test
|  |  |  |  |  \- org.glassfish.hk2.external:aopalliance-repackaged:2.6.1:test
|  |  |  |  +- org.glassfish.jersey.containers:jersey-container-servlet:2.40:test
|  |  |  |  +- org.glassfish.jersey.core:jersey-server:2.40:test
|  |  |  |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-json-provider:2.13.5:test
|  |  |  |  |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-base:2.13.5:test
|  |  |  |  |  \- com.fasterxml.jackson.module:jackson-module-jaxb-annotations:2.13.5:test
|  |  |  |  |     +- jakarta.xml.bind:jakarta.xml.bind-api:2.3.3:test
|  |  |  |  |     \- jakarta.activation:jakarta.activation-api:1.2.2:test
|  |  |  |  +- org.glassfish.jersey.containers:jersey-container-servlet-core:2.40:test
|  |  |  |  +- org.glassfish.jersey.core:jersey-client:2.40:test
|  |  |  |  \- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |  |  +- io.dropwizard:dropwizard-servlets:2.1.9:test
|  |  |  +- io.dropwizard:dropwizard-jetty:2.1.9:test
|  |  |  |  +- org.eclipse.jetty:jetty-servlets:9.4.53.v20231009:test
|  |  |  |  |  \- org.eclipse.jetty:jetty-continuation:9.4.53.v20231009:test
|  |  |  |  \- org.eclipse.jetty:jetty-http:9.4.53.v20231009:compile
|  |  |  |     \- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |  |  +- io.dropwizard:dropwizard-lifecycle:2.1.9:test
|  |  |  +- io.dropwizard.metrics:metrics-core:4.2.21:compile/test
|  |  |  +- io.dropwizard.metrics:metrics-annotation:4.2.21:test
|  |  |  +- io.dropwizard.metrics:metrics-healthchecks:4.2.21:test
|  |  |  +- io.dropwizard:dropwizard-request-logging:2.1.9:compile/test
|  |  |  |  \- ch.qos.logback:logback-access:1.2.12:compile/test
|  |  |  +- ch.qos.logback:logback-classic:1.2.12:compile/test
|  |  |  +- com.google.code.findbugs:jsr305:3.0.2:compile/test
|  |  |  +- jakarta.servlet:jakarta.servlet-api:4.0.4:compile/test
|  |  |  +- jakarta.validation:jakarta.validation-api:2.0.2:compile/test
|  |  |  +- jakarta.ws.rs:jakarta.ws.rs-api:2.1.6:test
|  |  |  +- net.sourceforge.argparse4j:argparse4j:0.9.0:test
|  |  |  +- org.eclipse.jetty:jetty-server:9.4.53.v20231009:compile/test
|  |  |  +- org.eclipse.jetty:jetty-util:9.4.53.v20231009:compile/test
|  |  |  +- org.glassfish.jersey.core:jersey-common:2.40:test
|  |  |  |  \- org.glassfish.hk2:osgi-resource-locator:1.0.3:test
|  |  |  \- org.hibernate.validator:hibernate-validator:6.2.5.Final:compile
|  |  |     \- org.jboss.logging:jboss-logging:3.4.1.Final:compile/test
|  |  +- io.dropwizard:dropwizard-jersey:2.1.9:test
|  |  |  +- org.glassfish.jersey.ext:jersey-metainf-services:2.40:test
|  |  |  +- org.glassfish.jersey.inject:jersey-hk2:2.40:test
|  |  |  |  \- org.glassfish.hk2:hk2-locator:2.6.1:test
|  |  |  +- org.javassist:javassist:3.29.2-GA:test
|  |  |  +- io.dropwizard.metrics:metrics-jersey2:4.2.21:test
|  |  |  +- jakarta.annotation:jakarta.annotation-api:1.3.5:test
|  |  |  +- joda-time:joda-time:2.12.5:compile/test
|  |  |  +- org.glassfish.hk2:hk2-api:2.6.1:test
|  |  |  |  +- org.glassfish.hk2:hk2-utils:2.6.1:test
|  |  |  |  \- org.glassfish.hk2.external:aopalliance-repackaged:2.6.1:test
|  |  |  +- org.glassfish.jersey.containers:jersey-container-servlet:2.40:test
|  |  |  +- org.glassfish.jersey.core:jersey-server:2.40:test
|  |  |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-json-provider:2.13.5:test
|  |  |  |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-base:2.13.5:test
|  |  |  |  \- com.fasterxml.jackson.module:jackson-module-jaxb-annotations:2.13.5:test
|  |  |  |     +- jakarta.xml.bind:jakarta.xml.bind-api:2.3.3:test
|  |  |  |     \- jakarta.activation:jakarta.activation-api:1.2.2:test
|  |  |  +- org.glassfish.jersey.containers:jersey-container-servlet-core:2.40:test
|  |  |  +- org.glassfish.jersey.core:jersey-client:2.40:test
|  |  |  \- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |  +- io.dropwizard:dropwizard-jetty:2.1.9:test
|  |  |  +- org.eclipse.jetty:jetty-servlets:9.4.53.v20231009:test
|  |  |  |  \- org.eclipse.jetty:jetty-continuation:9.4.53.v20231009:test
|  |  |  \- org.eclipse.jetty:jetty-http:9.4.53.v20231009:compile
|  |  |     \- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |  +- io.dropwizard:dropwizard-lifecycle:2.1.9:test
|  |  +- io.dropwizard:dropwizard-servlets:2.1.9:test
|  |  +- io.dropwizard:dropwizard-util:2.1.9:compile/test
|  |  |  \- com.google.guava:guava:32.1.3-jre:compile
|  |  |     +- com.google.guava:failureaccess:1.0.1:compile/test
|  |  |     +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |  |     +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |  |     +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |  |     \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |  +- io.dropwizard.metrics:metrics-annotation:4.2.21:test
|  |  +- io.dropwizard.metrics:metrics-healthchecks:4.2.21:test
|  |  +- com.fasterxml.jackson.datatype:jackson-datatype-guava:2.13.5:compile/test
|  |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-json-provider:2.13.5:test
|  |  |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-base:2.13.5:test
|  |  |  \- com.fasterxml.jackson.module:jackson-module-jaxb-annotations:2.13.5:test
|  |  |     +- jakarta.xml.bind:jakarta.xml.bind-api:2.3.3:test
|  |  |     \- jakarta.activation:jakarta.activation-api:1.2.2:test
|  |  +- jakarta.ws.rs:jakarta.ws.rs-api:2.1.6:test
|  |  +- net.sourceforge.argparse4j:argparse4j:0.9.0:test
|  |  +- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |  +- org.glassfish.jersey.containers:jersey-container-servlet-core:2.40:test
|  |  +- org.glassfish.jersey.connectors:jersey-grizzly-connector:2.40:test
|  |  |  +- org.glassfish.grizzly:grizzly-http-client:1.16:test
|  |  |  +- org.glassfish.grizzly:grizzly-websockets:2.4.4:test
|  |  |  |  +- org.glassfish.grizzly:grizzly-framework:2.4.4:test
|  |  |  |  \- org.glassfish.grizzly:grizzly-http:2.4.4:test
|  |  |  \- org.glassfish.grizzly:connection-pool:2.4.4:test
|  |  +- org.glassfish.jersey.core:jersey-client:2.40:test
|  |  +- org.glassfish.jersey.core:jersey-common:2.40:test
|  |  |  \- org.glassfish.hk2:osgi-resource-locator:1.0.3:test
|  |  +- org.glassfish.jersey.core:jersey-server:2.40:test
|  |  +- org.glassfish.jersey.test-framework:jersey-test-framework-core:2.40:test
|  |  |  +- org.glassfish.jersey.media:jersey-media-jaxb:2.40:test
|  |  |  +- org.junit.jupiter:junit-jupiter:5.8.2:test
|  |  |  \- org.hamcrest:hamcrest:2.2:test
|  |  +- org.glassfish.jersey.test-framework.providers:jersey-test-framework-provider-inmemory:2.40:test
|  |  +- jakarta.activation:jakarta.activation-api:1.2.2:test
|  |  \- jakarta.xml.bind:jakarta.xml.bind-api:2.3.3:test
|  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  \- commons-io:commons-io:2.7:compile
|  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
+- bike.cobi:cobi-bhu:5.0.0:compile
|  +- bike.cobi:cobi-core:5.0.0:compile
|  |  +- bike.cobi:cobi-neural-network-base:5.0.0:compile
|  |  |  +- org.apache.commons:commons-lang3:3.13.0:compile
|  |  |  +- commons-net:commons-net:3.9.0:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  |  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  |  \- commons-io:commons-io:2.7:compile
|  |  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  |  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  |  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
|  +- bike.cobi:cobi-core:5.0.0:test
|  +- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  |  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  |  +- com.carrotsearch:hppc:0.8.1:compile
|  |  +- org.codehaus.janino:janino:3.1.2:compile
|  |  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  |  +- org.locationtech.jts:jts-core:1.15.1:compile
|  |  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  |  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  |  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  |  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  |  \- commons-io:commons-io:2.7:compile
|  |  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  |  \- org.slf4j:slf4j-api:1.7.36:compile
|  +- com.bosch.ebike.graphhopper:graphhopper-nav:5.5.5:test
|  |  \- io.dropwizard:dropwizard-core:2.1.9:test
|  |     +- io.dropwizard:dropwizard-metrics:2.1.9:test
|  |     +- io.dropwizard:dropwizard-health:2.1.9:test
|  |     +- io.dropwizard.metrics:metrics-jetty9:4.2.21:test
|  |     +- io.dropwizard.metrics:metrics-jvm:4.2.21:test
|  |     +- io.dropwizard.metrics:metrics-jmx:4.2.21:test
|  |     +- io.dropwizard.metrics:metrics-servlets:4.2.21:test
|  |     |  +- io.dropwizard.metrics:metrics-json:4.2.21:test
|  |     |  \- com.helger:profiler:1.1.1:test
|  |     +- org.eclipse.jetty:jetty-security:9.4.53.v20231009:test
|  |     +- org.eclipse.jetty:jetty-servlet:9.4.53.v20231009:test
|  |     |  \- org.eclipse.jetty:jetty-util-ajax:9.4.53.v20231009:test
|  |     +- org.eclipse.jetty.toolchain.setuid:jetty-setuid-java:1.0.4:test
|  |     +- jakarta.inject:jakarta.inject-api:1.0.5:test
|  |     +- org.glassfish.jersey.ext:jersey-bean-validation:2.40:test
|  |     +- io.dropwizard:dropwizard-util:2.1.9:compile/test
|  |     |  \- com.google.guava:guava:32.1.3-jre:compile
|  |     |     +- com.google.guava:failureaccess:1.0.1:compile/test
|  |     |     +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |     |     +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |     |     +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |     |     \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |     +- io.dropwizard:dropwizard-jackson:2.1.9:compile
|  |     |  +- com.google.guava:guava:32.1.3-jre:compile
|  |     |  |  +- com.google.guava:failureaccess:1.0.1:compile/test
|  |     |  |  +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |     |  |  +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |     |  |  +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |     |  |  \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |     |  +- com.github.ben-manes.caffeine:caffeine:2.9.3:compile/test
|  |     |  +- com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.13.5:compile/test
|  |     |  +- com.fasterxml.jackson.datatype:jackson-datatype-jdk8:2.13.5:compile/test
|  |     |  +- com.fasterxml.jackson.module:jackson-module-parameter-names:2.13.5:compile/test
|  |     |  +- com.fasterxml.jackson.module:jackson-module-blackbird:2.13.5:compile/test
|  |     |  +- com.fasterxml.jackson.datatype:jackson-datatype-joda:2.13.5:compile
|  |     |  |  \- joda-time:joda-time:2.12.5:compile/test
|  |     |  +- com.fasterxml.jackson.datatype:jackson-datatype-guava:2.13.5:compile/test
|  |     |  \- io.dropwizard:dropwizard-util:2.1.9:compile/test
|  |     |     \- com.google.guava:guava:32.1.3-jre:compile
|  |     |        +- com.google.guava:failureaccess:1.0.1:compile/test
|  |     |        +- com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava:compile/test
|  |     |        +- org.checkerframework:checker-qual:3.39.0:compile/test
|  |     |        +- com.google.errorprone:error_prone_annotations:2.10.0:compile/test
|  |     |        \- com.google.j2objc:j2objc-annotations:2.8:compile/test
|  |     +- io.dropwizard:dropwizard-validation:2.1.9:compile
|  |     |  +- com.fasterxml:classmate:1.6.0:compile/test
|  |     |  +- org.hibernate.validator:hibernate-validator:6.2.5.Final:compile
|  |     |  |  \- org.jboss.logging:jboss-logging:3.4.1.Final:compile/test
|  |     |  \- org.glassfish:jakarta.el:3.0.4:runtime/test
|  |     +- io.dropwizard:dropwizard-configuration:2.1.9:test
|  |     |  +- com.fasterxml.jackson.dataformat:jackson-dataformat-yaml:2.13.5:test
|  |     |  |  \- org.yaml:snakeyaml:1.32:test
|  |     |  \- org.apache.commons:commons-text:1.10.0:test
|  |     +- io.dropwizard:dropwizard-logging:2.1.9:compile
|  |     |  +- io.dropwizard.metrics:metrics-logback:4.2.21:compile/test
|  |     |  +- org.slf4j:jul-to-slf4j:1.7.36:compile/test
|  |     |  +- io.dropwizard.logback:logback-throttling-appender:1.1.10:compile/test
|  |     |  +- org.slf4j:log4j-over-slf4j:1.7.36:runtime/test
|  |     |  +- org.slf4j:jcl-over-slf4j:1.7.36:runtime/test
|  |     |  +- org.eclipse.jetty:jetty-util:9.4.53.v20231009:compile/test
|  |     |  \- ch.qos.logback:logback-core:1.2.12:compile/test
|  |     +- io.dropwizard:dropwizard-jersey:2.1.9:test
|  |     |  +- org.glassfish.jersey.ext:jersey-metainf-services:2.40:test
|  |     |  +- org.glassfish.jersey.inject:jersey-hk2:2.40:test
|  |     |  |  \- org.glassfish.hk2:hk2-locator:2.6.1:test
|  |     |  +- org.javassist:javassist:3.29.2-GA:test
|  |     |  +- io.dropwizard.metrics:metrics-jersey2:4.2.21:test
|  |     |  +- jakarta.annotation:jakarta.annotation-api:1.3.5:test
|  |     |  +- joda-time:joda-time:2.12.5:compile/test
|  |     |  +- org.glassfish.hk2:hk2-api:2.6.1:test
|  |     |  |  +- org.glassfish.hk2:hk2-utils:2.6.1:test
|  |     |  |  \- org.glassfish.hk2.external:aopalliance-repackaged:2.6.1:test
|  |     |  +- org.glassfish.jersey.containers:jersey-container-servlet:2.40:test
|  |     |  +- org.glassfish.jersey.core:jersey-server:2.40:test
|  |     |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-json-provider:2.13.5:test
|  |     |  |  +- com.fasterxml.jackson.jaxrs:jackson-jaxrs-base:2.13.5:test
|  |     |  |  \- com.fasterxml.jackson.module:jackson-module-jaxb-annotations:2.13.5:test
|  |     |  |     +- jakarta.xml.bind:jakarta.xml.bind-api:2.3.3:test
|  |     |  |     \- jakarta.activation:jakarta.activation-api:1.2.2:test
|  |     |  +- org.glassfish.jersey.containers:jersey-container-servlet-core:2.40:test
|  |     |  +- org.glassfish.jersey.core:jersey-client:2.40:test
|  |     |  \- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |     +- io.dropwizard:dropwizard-servlets:2.1.9:test
|  |     +- io.dropwizard:dropwizard-jetty:2.1.9:test
|  |     |  +- org.eclipse.jetty:jetty-servlets:9.4.53.v20231009:test
|  |     |  |  \- org.eclipse.jetty:jetty-continuation:9.4.53.v20231009:test
|  |     |  \- org.eclipse.jetty:jetty-http:9.4.53.v20231009:compile
|  |     |     \- org.eclipse.jetty:jetty-io:9.4.53.v20231009:compile/test
|  |     +- io.dropwizard:dropwizard-lifecycle:2.1.9:test
|  |     +- io.dropwizard.metrics:metrics-core:4.2.21:compile/test
|  |     +- io.dropwizard.metrics:metrics-annotation:4.2.21:test
|  |     +- io.dropwizard.metrics:metrics-healthchecks:4.2.21:test
|  |     +- io.dropwizard:dropwizard-request-logging:2.1.9:compile/test
|  |     |  \- ch.qos.logback:logback-access:1.2.12:compile/test
|  |     +- ch.qos.logback:logback-classic:1.2.12:compile/test
|  |     +- com.google.code.findbugs:jsr305:3.0.2:compile/test
|  |     +- jakarta.servlet:jakarta.servlet-api:4.0.4:compile/test
|  |     +- jakarta.validation:jakarta.validation-api:2.0.2:compile/test
|  |     +- jakarta.ws.rs:jakarta.ws.rs-api:2.1.6:test
|  |     +- net.sourceforge.argparse4j:argparse4j:0.9.0:test
|  |     +- org.eclipse.jetty:jetty-server:9.4.53.v20231009:compile/test
|  |     +- org.eclipse.jetty:jetty-util:9.4.53.v20231009:compile/test
|  |     +- org.glassfish.jersey.core:jersey-common:2.40:test
|  |     |  \- org.glassfish.hk2:osgi-resource-locator:1.0.3:test
|  |     \- org.hibernate.validator:hibernate-validator:6.2.5.Final:compile
|  |        \- org.jboss.logging:jboss-logging:3.4.1.Final:compile/test
|  +- org.junit.platform:junit-platform-launcher:1.8.2:test
|  |  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  |  \- org.apiguardian:apiguardian-api:1.1.2:test
|  +- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  |  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
|  \- org.junit.jupiter:junit-jupiter-params:5.8.2:test
+- com.bosch.ebike.graphhopper:graphhopper-core:5.5.5:compile
|  +- com.bosch.ebike.graphhopper:graphhopper-web-api:5.5.5:compile
|  +- com.carrotsearch:hppc:0.8.1:compile
|  +- org.codehaus.janino:janino:3.1.2:compile
|  |  \- org.codehaus.janino:commons-compiler:3.1.2:compile
|  +- org.locationtech.jts:jts-core:1.15.1:compile
|  +- com.fasterxml.jackson.core:jackson-core:2.13.5:compile
|  +- com.fasterxml.jackson.core:jackson-databind:2.13.5:compile
|  |  \- com.fasterxml.jackson.core:jackson-annotations:2.13.5:compile
|  +- com.graphhopper.external:jackson-datatype-jts:0.12-2.5-1:compile
|  +- com.fasterxml.jackson.dataformat:jackson-dataformat-xml:2.13.5:compile
|  |  +- org.codehaus.woodstox:stax2-api:4.2.1:compile
|  |  \- com.fasterxml.woodstox:woodstox-core:6.4.0:compile
|  +- org.apache.xmlgraphics:xmlgraphics-commons:2.7:compile
|  |  \- commons-io:commons-io:2.7:compile
|  +- org.openstreetmap.osmosis:osmosis-osm-binary:0.47.3:compile
|  |  \- com.google.protobuf:protobuf-java:3.16.3:compile
|  \- org.slf4j:slf4j-api:1.7.36:compile
+- org.junit.platform:junit-platform-launcher:1.8.2:test
|  +- org.junit.platform:junit-platform-engine:1.8.2:test
|  |  +- org.opentest4j:opentest4j:1.2.0:test
|  |  \- org.junit.platform:junit-platform-commons:1.8.2:test
|  \- org.apiguardian:apiguardian-api:1.1.2:test
+- org.junit.jupiter:junit-jupiter-engine:5.8.2:test
|  \- org.junit.jupiter:junit-jupiter-api:5.8.2:test
\- org.junit.jupiter:junit-jupiter-params:5.8.2:test|]
