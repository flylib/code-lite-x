// 随 IDE 打包的插件目录(插件市场索引的离线版本,格式见 plugin_manifest.dart)。
// 以后从插件市场服务器拉取同样格式的 JSON,这份作为离线兜底。
const String builtinPluginCatalog = r'''
{
  "version": 1,
  "plugins": [
    {
      "id": "codelitex.java",
      "name": "Java",
      "version": "1.61.0",
      "publisher": "CodeLiteX",
      "description": "Java 语言支持:Eclipse JDT Language Server(jdtls)提供错误检查、文件大纲,支持 Maven / Gradle 项目。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 50,
      "requires": [
        {
          "java": 21,
          "hint": "jdtls 需要 JDK 21 或更新版本运行(只用于运行语言服务器,不影响项目本身的 JDK)。可从 https://adoptium.net 安装。"
        }
      ],
      "contributes": {
        "languages": [
          {
            "id": "java",
            "name": "Java",
            "extensions": [
              "java"
            ]
          }
        ],
        "languageServers": [
          {
            "group": "java",
            "languages": [
              "java"
            ],
            "name": "Eclipse JDT Language Server",
            "command": [
              "${javaHome:21}/bin/java",
              "-Declipse.application=org.eclipse.jdt.ls.core.id1",
              "-Dosgi.bundles.defaultStartLevel=4",
              "-Declipse.product=org.eclipse.jdt.ls.core.product",
              "-Dosgi.checkConfiguration=true",
              "-Dosgi.sharedConfiguration.area=${pluginDir}/server/${eclipseConfig}",
              "-Dosgi.sharedConfiguration.area.readOnly=true",
              "-Dosgi.configuration.cascaded=true",
              "-Xms256m",
              "-Xmx1G",
              "--add-modules=ALL-SYSTEM",
              "--add-opens",
              "java.base/java.util=ALL-UNNAMED",
              "--add-opens",
              "java.base/java.lang=ALL-UNNAMED",
              "-jar",
              "${glob:server/plugins/org.eclipse.equinox.launcher_*.jar}",
              "-configuration",
              "${dataDir}/config",
              "-data",
              "${dataDir}/workspace"
            ],
            "env": {
              "JAVA_HOME": "${javaHome:21}"
            },
            "initializeTimeoutSeconds": 180,
            "requestTimeoutSeconds": 60,
            "detect": [
              "jdtls"
            ]
          }
        ]
      },
      "install": [
        {
          "download": "https://download.eclipse.org/jdtls/milestones/1.61.0/jdt-language-server-1.61.0-202609031315.tar.gz",
          "extract": "tar.gz",
          "to": "server"
        }
      ]
    },
    {
      "id": "codelitex.go",
      "name": "Go",
      "version": "0.23.0",
      "publisher": "CodeLiteX",
      "description": "Go 语言支持:官方语言服务器 gopls。通过本机的 go 命令安装到插件目录。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 40,
      "requires": [
        {
          "tool": "go",
          "hint": "需要先安装 Go:https://go.dev/dl/"
        }
      ],
      "contributes": {
        "languages": [
          {
            "id": "go",
            "name": "Go",
            "extensions": [
              "go"
            ]
          }
        ],
        "languageServers": [
          {
            "group": "go",
            "languages": [
              "go"
            ],
            "name": "gopls",
            "command": [
              "${pluginDir}/bin/gopls${exe}"
            ],
            "detect": [
              "gopls"
            ]
          }
        ]
      },
      "install": [
        {
          "run": [
            "${tool:go}",
            "install",
            "golang.org/x/tools/gopls@latest"
          ],
          "env": {
            "GOBIN": "${pluginDir}/bin"
          }
        }
      ]
    },
    {
      "id": "codelitex.typescript",
      "name": "TypeScript / JavaScript",
      "version": "6.0.1",
      "publisher": "CodeLiteX",
      "description": "TypeScript、JavaScript、TSX/JSX 语言支持:typescript-language-server + tsserver。通过本机的 npm 安装到插件目录。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 30,
      "requires": [
        {
          "tool": "npm",
          "hint": "需要先安装 Node.js(自带 npm):https://nodejs.org"
        }
      ],
      "contributes": {
        "languages": [
          {
            "id": "typescript",
            "name": "TypeScript",
            "extensions": [
              "ts",
              "tsx",
              "mts",
              "cts"
            ]
          },
          {
            "id": "javascript",
            "name": "JavaScript",
            "extensions": [
              "js",
              "jsx",
              "mjs",
              "cjs"
            ]
          }
        ],
        "languageServers": [
          {
            "group": "typescript",
            "languages": [
              "typescript",
              "typescriptreact",
              "javascript",
              "javascriptreact"
            ],
            "name": "typescript-language-server",
            "command": [
              "${pluginDir}/node_modules/.bin/typescript-language-server",
              "--stdio"
            ],
            "detect": [
              "vtsls",
              "typescript-language-server"
            ]
          }
        ]
      },
      "install": [
        {
          "run": [
            "${tool:npm}",
            "install",
            "--prefix",
            "${pluginDir}",
            "--no-audit",
            "--no-fund",
            "typescript",
            "typescript-language-server"
          ]
        }
      ]
    },
    {
      "id": "codelitex.python",
      "name": "Python",
      "version": "1.1.0",
      "publisher": "CodeLiteX",
      "description": "Python 语言支持:Pyright 语言服务器(类型检查、错误提示、大纲)。通过本机的 npm 安装到插件目录。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 20,
      "requires": [
        {
          "tool": "npm",
          "hint": "Pyright 通过 npm 安装,需要先装 Node.js:https://nodejs.org"
        }
      ],
      "contributes": {
        "languages": [
          {
            "id": "python",
            "name": "Python",
            "extensions": [
              "py",
              "pyi"
            ]
          }
        ],
        "languageServers": [
          {
            "group": "python",
            "languages": [
              "python"
            ],
            "name": "Pyright",
            "command": [
              "${pluginDir}/node_modules/.bin/pyright-langserver",
              "--stdio"
            ],
            "detect": [
              "pyright-langserver",
              "basedpyright-langserver",
              "pylsp"
            ]
          }
        ]
      },
      "install": [
        {
          "run": [
            "${tool:npm}",
            "install",
            "--prefix",
            "${pluginDir}",
            "--no-audit",
            "--no-fund",
            "pyright"
          ]
        }
      ]
    },
    {
      "id": "codelitex.rust",
      "name": "Rust",
      "version": "latest",
      "publisher": "CodeLiteX",
      "description": "Rust 语言支持:rust-analyzer(官方预编译版本,从 GitHub Releases 下载)。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 14,
      "contributes": {
        "languages": [
          {
            "id": "rust",
            "name": "Rust",
            "extensions": [
              "rs"
            ]
          }
        ],
        "languageServers": [
          {
            "group": "rust",
            "languages": [
              "rust"
            ],
            "name": "rust-analyzer",
            "command": [
              "${pluginDir}/bin/rust-analyzer${exe}"
            ],
            "detect": [
              "rust-analyzer"
            ]
          }
        ]
      },
      "install": [
        {
          "download": {
            "darwin-arm64": "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-aarch64-apple-darwin.gz",
            "darwin-x64": "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-apple-darwin.gz",
            "linux-x64": "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-unknown-linux-gnu.gz",
            "linux-arm64": "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-aarch64-unknown-linux-gnu.gz",
            "win32-x64": "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-pc-windows-msvc.gz"
          },
          "extract": "gz",
          "to": "bin/rust-analyzer${exe}",
          "executable": true
        }
      ]
    },
    {
      "id": "codelitex.cpp",
      "name": "C / C++",
      "version": "23.1.0",
      "publisher": "CodeLiteX",
      "description": "C、C++ 语言支持:clangd(LLVM 官方发布版)。macOS 装了 Xcode 命令行工具时已自带,无需下载。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 95,
      "contributes": {
        "languages": [
          {
            "id": "cpp",
            "name": "C++",
            "extensions": [
              "cpp",
              "cc",
              "cxx",
              "hpp",
              "hh",
              "hxx"
            ]
          },
          {
            "id": "c",
            "name": "C",
            "extensions": [
              "c",
              "h"
            ]
          }
        ],
        "languageServers": [
          {
            "group": "cpp",
            "languages": [
              "cpp",
              "c"
            ],
            "name": "clangd",
            "command": [
              "${glob:server/clangd_*/bin/clangd${exe}}"
            ],
            "detect": [
              "clangd"
            ]
          }
        ]
      },
      "install": [
        {
          "download": {
            "darwin-arm64": "https://github.com/clangd/clangd/releases/download/23.1.0/clangd-mac-23.1.0.zip",
            "darwin-x64": "https://github.com/clangd/clangd/releases/download/23.1.0/clangd-mac-23.1.0.zip",
            "linux-x64": "https://github.com/clangd/clangd/releases/download/23.1.0/clangd-linux-23.1.0.zip",
            "win32-x64": "https://github.com/clangd/clangd/releases/download/23.1.0/clangd-windows-23.1.0.zip"
          },
          "extract": "zip",
          "to": "server"
        }
      ]
    },
    {
      "id": "codelitex.scala",
      "name": "Scala",
      "version": "1.0.0",
      "publisher": "CodeLiteX",
      "description": "Scala 语法高亮。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 0,
      "contributes": {
        "languages": [
          {
            "id": "scala",
            "name": "Scala",
            "extensions": [
              "scala",
              "sc",
              "sbt"
            ],
            "syntax": {
              "keywords": [
                "abstract",
                "case",
                "catch",
                "class",
                "def",
                "do",
                "else",
                "extends",
                "final",
                "finally",
                "for",
                "forSome",
                "if",
                "implicit",
                "import",
                "lazy",
                "match",
                "new",
                "object",
                "override",
                "package",
                "private",
                "protected",
                "return",
                "sealed",
                "super",
                "this",
                "throw",
                "trait",
                "try",
                "type",
                "val",
                "var",
                "while",
                "with",
                "yield",
                "given",
                "using",
                "enum",
                "then",
                "export"
              ],
              "constants": [
                "true",
                "false",
                "null"
              ],
              "lineComments": [
                "//"
              ],
              "blockComments": [
                [
                  "/**",
                  "*/"
                ],
                [
                  "/*",
                  "*/"
                ]
              ],
              "docComment": "/**",
              "strings": [
                {
                  "open": "\"\"\"",
                  "close": "\"\"\"",
                  "multiline": true,
                  "escapes": false
                },
                "\"",
                {
                  "open": "'",
                  "close": "'",
                  "maxLength": 12
                }
              ],
              "annotation": "@",
              "upperCaseIsType": true
            }
          }
        ]
      },
      "install": []
    },
    {
      "id": "codelitex.lua",
      "name": "Lua",
      "version": "1.0.0",
      "publisher": "CodeLiteX",
      "description": "Lua 语法高亮。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 0,
      "contributes": {
        "languages": [
          {
            "id": "lua",
            "name": "Lua",
            "extensions": [
              "lua"
            ],
            "syntax": {
              "shebangs": [
                "lua"
              ],
              "keywords": [
                "and",
                "break",
                "do",
                "else",
                "elseif",
                "end",
                "for",
                "function",
                "goto",
                "if",
                "in",
                "local",
                "not",
                "or",
                "repeat",
                "return",
                "then",
                "until",
                "while"
              ],
              "constants": [
                "true",
                "false",
                "nil"
              ],
              "lineComments": [
                "--"
              ],
              "blockComments": [
                [
                  "--[[",
                  "]]"
                ]
              ],
              "strings": [
                {
                  "open": "[[",
                  "close": "]]",
                  "multiline": true,
                  "escapes": false
                },
                "\"",
                "'"
              ]
            }
          }
        ]
      },
      "install": []
    },
    {
      "id": "codelitex.powershell",
      "name": "PowerShell",
      "version": "1.0.0",
      "publisher": "CodeLiteX",
      "description": "PowerShell 语法高亮。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 0,
      "contributes": {
        "languages": [
          {
            "id": "powershell",
            "name": "PowerShell",
            "extensions": [
              "ps1",
              "psm1",
              "psd1"
            ],
            "syntax": {
              "keywords": [
                "begin",
                "break",
                "catch",
                "class",
                "continue",
                "data",
                "do",
                "dynamicparam",
                "else",
                "elseif",
                "end",
                "exit",
                "filter",
                "finally",
                "for",
                "foreach",
                "from",
                "function",
                "if",
                "in",
                "param",
                "process",
                "return",
                "switch",
                "throw",
                "trap",
                "try",
                "until",
                "using",
                "while"
              ],
              "constants": [
                "$true",
                "$false",
                "$null"
              ],
              "lineComments": [
                "#"
              ],
              "blockComments": [
                [
                  "<#",
                  "#>"
                ]
              ],
              "strings": [
                "\"",
                "'"
              ],
              "caseInsensitive": true,
              "variableSigil": "$"
            }
          }
        ]
      },
      "install": []
    },
    {
      "id": "codelitex.protobuf",
      "name": "Protocol Buffers",
      "version": "1.0.0",
      "publisher": "CodeLiteX",
      "description": "Protocol Buffers(.proto)语法高亮。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 0,
      "contributes": {
        "languages": [
          {
            "id": "proto",
            "name": "Protocol Buffers",
            "extensions": [
              "proto"
            ],
            "syntax": {
              "keywords": [
                "syntax",
                "package",
                "import",
                "option",
                "message",
                "enum",
                "service",
                "rpc",
                "returns",
                "repeated",
                "optional",
                "required",
                "oneof",
                "map",
                "reserved",
                "extend",
                "stream",
                "public",
                "weak"
              ],
              "types": [
                "double",
                "float",
                "int32",
                "int64",
                "uint32",
                "uint64",
                "sint32",
                "sint64",
                "fixed32",
                "fixed64",
                "sfixed32",
                "sfixed64",
                "bool",
                "string",
                "bytes"
              ],
              "constants": [
                "true",
                "false"
              ],
              "lineComments": [
                "//"
              ],
              "blockComments": [
                [
                  "/*",
                  "*/"
                ]
              ],
              "strings": [
                "\"",
                "'"
              ],
              "upperCaseIsType": true
            }
          }
        ]
      },
      "install": []
    },
    {
      "id": "codelitex.graphql",
      "name": "GraphQL",
      "version": "1.0.0",
      "publisher": "CodeLiteX",
      "description": "GraphQL 语法高亮。",
      "categories": [
        "Programming Languages"
      ],
      "sizeMB": 0,
      "contributes": {
        "languages": [
          {
            "id": "graphql",
            "name": "GraphQL",
            "extensions": [
              "graphql",
              "gql"
            ],
            "syntax": {
              "keywords": [
                "query",
                "mutation",
                "subscription",
                "fragment",
                "on",
                "type",
                "interface",
                "union",
                "enum",
                "input",
                "scalar",
                "schema",
                "extend",
                "implements",
                "directive"
              ],
              "types": [
                "Int",
                "Float",
                "String",
                "Boolean",
                "ID"
              ],
              "constants": [
                "true",
                "false",
                "null"
              ],
              "lineComments": [
                "#"
              ],
              "strings": [
                {
                  "open": "\"\"\"",
                  "close": "\"\"\"",
                  "multiline": true
                },
                "\""
              ],
              "annotation": "@",
              "upperCaseIsType": true
            }
          }
        ]
      },
      "install": []
    }
  ]
}
''';
