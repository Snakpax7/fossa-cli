# Supported Languages

<!-- add table here

- Analyzers
  - By language
  - By platform
    - Might have duplicates
      - Carthage is both "iOS" as platform and "Objective-C" as language
      - .NET is platform, C# is language
      - Conda is platform, Python is language
    - TODO: add scripting/linting to let us say "file at this folder location is the same as other file" and check that their contents are identical (e.g. so we can duplicate Carthage file under both iOS and Objective-C)
  - System deps
  - Others
    - Docker
-->

### clojure

- [leiningen](languages/clojure/leiningen.md)

### C/C++

- [C](languages/c-cpp/c-cpp.md)
- [C++](languages/c-cpp/c-cpp.md)

In order to use these strategies special options must be provided to the CLI.
See the linked documentation above for details.

### dart

- [pub](languages/dart/pub.md)

### erlang

- [rebar3](languages/erlang/erlang.md)

### elixir

- [mix](languages/elixir/mix.md)

### fortran

- [fortran](languages/fortran/fortran.md)

### go

- [gomodules (`go mod`)](languages/golang/gomodules.md)
- [dep](languages/golang/godep.md)
- [glide](languages/golang/glide.md)

### haskell

- [cabal](languages/haskell/cabal.md)
- [stack](languages/haskell/stack.md)

### java

- [maven](languages/maven/maven.md)
- [gradle](languages/gradle/gradle.md)

### javascript/typescript

- [yarn](languages/nodejs/yarn.md)
- [npm](languages/nodejs/npm.md)
- [pnpm](languages/nodejs/pnpm.md)

### nim

- [Nimble](languages/nim/nimble.md)

### .NET

- [NuGet](languages/dotnet/nuget.md)
- [Paket](languages/dotnet/paket.md)

### objective-c

- [carthage](platforms/ios/carthage.md)
- [cocoapods](platforms/ios/cocoapods.md)

### perl

- [perl](languages/perl/perl.md)

### php

- [php](languages/php/composer.md)

### python

- [conda](languages/python/conda.md)
- [`requirements.txt`/`setup.py`](languages/python/python.md)
- [pipenv](languages/python/pipenv.md)
- [poetry](languages/python/poetry.md)
- [pdm](languages/python/pdm.md)

### r

- [renv](languages/r/renv.md)

### ruby

- [bundler](languages/ruby/bundler.md)

### rust

- [cargo](languages/rust/cargo.md)

### scala

- [sbt](languages/scala/sbt.md)
- [gradle](languages/gradle/gradle.md)
- [maven](languages/maven/maven.md)

### swift

- [carthage](platforms/ios/carthage.md)
- [cocoapods](platforms/ios/cocoapods.md)
- [swiftPM](platforms/ios/swift.md)

## Static and Dynamic Strategies

Languages supported by FOSSA CLI can have multiple strategies for detecting dependencies, one primary strategy that yields ideal results and zero or more fallback strategies. Within this list of strategies, we have the concept of _static_ and _dynamic_ strategies. Static strategies parse files to find a dependency graph (example: parse a `package-lock.json` file). Dynamic strategies are required when analyzing package managers that do not offer complete lockfiles, such as Gradle or Go. Dynamic strategies require a working build environment to operate in.

Running the tool with all possible strategies enabled is recommended, but if you need to limit FOSSA CLI to only use static strategies the CLI offers the `--static-only-analysis` flag.
This flag prevents FOSSA CLI from using any third party tools, such as `npm`, `pip`, maven plugins, etc.
With this option enabled, strategies that don't offer a way to analyze statically will fail with an error.

It is important to note that neither type of strategy has an inherent benefit when detecting dependencies. If a supported language has only a static or only a dynamic strategy, this does not mean it is less supported than a language that has both.

## Strict Analysis

Strict analysis enforces the use of the most accurate strategy for detecting dependencies, ensuring precise and consistent results by rejecting fallback methods that may offer less reliable detection.

For example, in Maven projects, FOSSA CLI attempts analysis with the following strategy order:

1. Run the [mavenplugin](../strategies/languages/maven/mavenplugin.md) strategy, which provides the most accurate dependency information.
2. If that fails, it attempts the [treecmd](../strategies/languages/maven/treecmd.md) strategy, which parses the output of the `mvn dependency:tree` command.
3. Finally, it falls back to the [pomxml](../strategies/languages/maven/pomxml.md) strategy, scanning pom.xml files for dependencies.

However, with the `--strict` flag, only the `mavenplugin` strategy will be used. If the `mavenplugin` command fails, FOSSA will not attempt the `treecmd` or `pomxml` methods. This ensures that your Maven analysis relies solely on the most precise and validated strategy.

Invoke strict analysis with the `--strict` flag when running `fossa analyze`.

### Strategies by type

> [!NOTE]
> Dynamic strategies require a working build environment for analysis.
>
> If a given package manager has a dynamic strategy with a static fallback, that means the static fallback provides worse results,
> so it is only used when the dynamic strategy fails. If the package manager only has static strategies, that means dynamic analysis
> is not required for ideal results.

> [!TIP]
> If FOSSA CLI is forced to utilize a fallback strategy, meaning it did not detect ideal results,
> a warning is emitted in the scan summary after running `fossa analyze`.

> [!WARNING]
> "Custom" strategies work very differently than the standard package manager based analysis; read their docs for more details.

| Language/Package Manager                                                                                                                        | Kind of analysis             | Detect Vendored Code |
|-------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------|----------------------|
| [C#/.NET (nuget)](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/dotnet/nuspec.md)                        | Static                       | ❌                    |
| [C#/.NET (packagereference)](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/dotnet/packagereference.md)   | Static                       | ❌                    |
| [C#/.NET (packagesconfig)](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/dotnet/packagesconfig.md)       | Static                       | ❌                    |
| [C#/.NET (paket)](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/dotnet/paket.md)                         | Static                       | ❌                    |
| [C#/.NET (projectassetsjson)](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/dotnet/projectassetsjson.md) | Static                       | ❌                    |
| [C#/.NET (projectjson)](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/dotnet/projectjson.md)             | Static                       | ❌                    |
| [C](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/c-cpp/c-cpp.md)                                        | Custom                       | ✅                    |
| [C++](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/c-cpp/c-cpp.md)                                      | Custom                       | ✅                    |
| [Clojure (leiningen)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/clojure/clojure.md)                  | Dynamic                      | ❌                    |
| [Dart (pub)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/dart/dart.md)                                 | Dynamic with static fallback | ❌                    |
| [Elixer (mix)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/elixir/elixir.md)                           | Dynamic                      | ❌                    |
| [Erlang (rebar3)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/erlang/erlang.md)                        | Dynamic                      | ❌                    |
| [Fortran](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/fortran/fortran.md)                              | Static                       | ❌                    |
| [Go (dep)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/golang/godep.md)                                | Static                       | ❌                    |
| [Go (glide)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/golang/glide.md)                              | Static                       | ❌                    |
| [Go (gomodules)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/golang/gomodules.md)                      | Dynamic with static fallback | ❌                    |
| [Gradle](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/gradle/gradle.md)                                 | Dynamic                      | ❌                    |
| [Haskell (cabal)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/haskell/cabal.md)                        | Dynamic                      | ❌                    |
| [Haskell (stack)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/haskell/stack.md)                        | Dynamic                      | ❌                    |
| [iOS (carthage)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/platforms/ios/carthage.md)                          | Static                       | ❌                    |
| [iOS (cocoapods)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/platforms/ios/cocoapods.md)                        | Static                       | ❌                    |
| [iOS (swift)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/platforms/ios/swift.md)                                | Static                       | ❌                    |
| [Maven](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/maven/maven.md)                                    | Dynamic with static fallback | ❌                    |
| [NodeJS (NPM/Yarn/pnpm)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/nodejs/nodejs.md)                 | Static                       | ❌                    |
| [Perl](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/perl/perl.md)                                       | Static                       | ❌                    |
| [PHP (Composer)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/php/composer.md)                          | Static                       | ❌                    |
| [Python (Conda)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/python/conda.md)                          | Dynamic with static fallback | ❌                    |
| [Python (Pipenv)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/python/pipenv.md)                        | Dynamic with static fallback | ❌                    |
| [Python (Poetry)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/python/poetry.md)                        | Static                       | ❌                    |
| [Python (Pdm)](./languages/python/pdm.md)                                                                                                       | Static                       | ❌                    |
| [Python (setup.py/requirements.txt)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/python/setuptools.md) | Dynamic with static fallback | ❌                    |
| [R (renv)](./languages/r/renv.md)                                                                                                               | Static                       | ❌                    |
| [Ruby (bundler)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/ruby/ruby.md)                             | Dynamic with static fallback | ❌                    |
| [Rust (cargo)](https://github.com/fossas/fossa-cli/blob/master/docs/references/strategies/languages/rust/rust.md)                               | Dynamic                      | ❌                    |
| [Scala (sbt)](https://github.com/fossas/fossa-cli/tree/master/docs/references/strategies/languages/scala)                                       | Dynamic                      | ❌                    |
