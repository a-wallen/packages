// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show Directory, File, FileSystemEntity;

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart' as yaml;

import 'ast.dart';
import 'functional.dart';
import 'generator_tools.dart';

/// Documentation comment open symbol.
const String _docCommentPrefix = '///';

/// Documentation comment spec.
const DocumentCommentSpecification _docCommentSpec =
    DocumentCommentSpecification(_docCommentPrefix);

/// The standard codec for Flutter, used for any non custom codecs and extended for custom codecs.
const String _standardMessageCodec = 'StandardMessageCodec';

/// Options that control how Dart code will be generated.
class DartOptions {
  /// Constructor for DartOptions.
  const DartOptions({this.copyrightHeader});

  /// A copyright header that will get prepended to generated code.
  final Iterable<String>? copyrightHeader;

  /// Creates a [DartOptions] from a Map representation where:
  /// `x = DartOptions.fromMap(x.toMap())`.
  static DartOptions fromMap(Map<String, Object> map) {
    final Iterable<dynamic>? copyrightHeader =
        map['copyrightHeader'] as Iterable<dynamic>?;
    return DartOptions(
      copyrightHeader: copyrightHeader?.cast<String>(),
    );
  }

  /// Converts a [DartOptions] to a Map representation where:
  /// `x = DartOptions.fromMap(x.toMap())`.
  Map<String, Object> toMap() {
    final Map<String, Object> result = <String, Object>{
      if (copyrightHeader != null) 'copyrightHeader': copyrightHeader!,
    };
    return result;
  }

  /// Overrides any non-null parameters from [options] into this to make a new
  /// [DartOptions].
  DartOptions merge(DartOptions options) {
    return DartOptions.fromMap(mergeMaps(toMap(), options.toMap()));
  }
}

String _escapeForDartSingleQuotedString(String raw) {
  return raw
      .replaceAll(r'\', r'\\')
      .replaceAll(r'$', r'\$')
      .replaceAll(r"'", r"\'");
}

/// Calculates the name of the codec class that will be generated for [api].
String _getCodecName(Api api) => '_${api.name}Codec';

/// Writes the codec that will be used by [api].
/// Example:
///
/// class FooCodec extends StandardMessageCodec {...}
void _writeCodec(Indent indent, String codecName, Api api, Root root) {
  assert(getCodecClasses(api, root).isNotEmpty);
  final Iterable<EnumeratedClass> codecClasses = getCodecClasses(api, root);
  indent.write('class $codecName extends $_standardMessageCodec');
  indent.scoped('{', '}', () {
    indent.writeln('const $codecName();');
    indent.writeln('@override');
    indent.write('void writeValue(WriteBuffer buffer, Object? value) ');
    indent.scoped('{', '}', () {
      for (final EnumeratedClass customClass in codecClasses) {
        indent.write('if (value is ${customClass.name}) ');
        indent.scoped('{', '} else ', () {
          indent.writeln('buffer.putUint8(${customClass.enumeration});');
          indent.writeln('writeValue(buffer, value.encode());');
        });
      }
      indent.scoped('{', '}', () {
        indent.writeln('super.writeValue(buffer, value);');
      });
    });
    indent.writeln('@override');
    indent.write('Object? readValueOfType(int type, ReadBuffer buffer) ');
    indent.scoped('{', '}', () {
      indent.write('switch (type) ');
      indent.scoped('{', '}', () {
        for (final EnumeratedClass customClass in codecClasses) {
          indent.write('case ${customClass.enumeration}: ');
          indent.writeScoped('', '', () {
            indent.writeln(
                'return ${customClass.name}.decode(readValue(buffer)!);');
          });
        }
        indent.write('default:');
        indent.writeScoped('', '', () {
          indent.writeln('return super.readValueOfType(type, buffer);');
        });
      });
    });
  });
}

/// Creates a Dart type where all type arguments are [Objects].
String _makeGenericTypeArguments(TypeDeclaration type) {
  return type.typeArguments.isNotEmpty
      ? '${type.baseName}<${type.typeArguments.map<String>((TypeDeclaration e) => 'Object?').join(', ')}>'
      : _addGenericTypes(type);
}

/// Creates a `.cast<>` call for an type. Returns an empty string if the
/// type has no type arguments.
String _makeGenericCastCall(TypeDeclaration type) {
  return type.typeArguments.isNotEmpty
      ? '.cast<${_flattenTypeArguments(type.typeArguments)}>()'
      : '';
}

/// Returns an argument name that can be used in a context where it is possible to collide.
String _getSafeArgumentName(int count, NamedType field) =>
    field.name.isEmpty ? 'arg$count' : 'arg_${field.name}';

/// Generates an argument name if one isn't defined.
String _getArgumentName(int count, NamedType field) =>
    field.name.isEmpty ? 'arg$count' : field.name;

/// Generates the arguments code for [func]
/// Example: (func, getArgumentName) -> 'String? foo, int bar'
String _getMethodArgumentsSignature(
  Method func,
  String Function(int index, NamedType arg) getArgumentName,
) {
  return func.arguments.isEmpty
      ? ''
      : indexMap(func.arguments, (int index, NamedType arg) {
          final String type = _addGenericTypesNullable(arg.type);
          final String argName = getArgumentName(index, arg);
          return '$type $argName';
        }).join(', ');
}

/// Writes the code for host [Api], [api].
/// Example:
/// class FooCodec extends StandardMessageCodec {...}
///
/// class Foo {
///   Foo(BinaryMessenger? binaryMessenger) {}
///   static const MessageCodec<Object?> codec = FooCodec();
///   Future<int> add(int x, int y) async {...}
/// }
void _writeHostApi(DartOptions opt, Indent indent, Api api, Root root) {
  assert(api.location == ApiLocation.host);
  String codecName = _standardMessageCodec;
  if (getCodecClasses(api, root).isNotEmpty) {
    codecName = _getCodecName(api);
    _writeCodec(indent, codecName, api, root);
  }
  indent.addln('');
  bool first = true;
  addDocumentationComments(indent, api.documentationComments, _docCommentSpec);
  indent.write('class ${api.name} ');
  indent.scoped('{', '}', () {
    indent.format('''
/// Constructor for [${api.name}].  The [binaryMessenger] named argument is
/// available for dependency injection.  If it is left null, the default
/// BinaryMessenger will be used which routes to the host platform.
${api.name}({BinaryMessenger? binaryMessenger}) : _binaryMessenger = binaryMessenger;
final BinaryMessenger? _binaryMessenger;
''');

    indent.writeln('static const MessageCodec<Object?> codec = $codecName();');
    indent.addln('');
    for (final Method func in api.methods) {
      if (!first) {
        indent.writeln('');
      } else {
        first = false;
      }
      addDocumentationComments(
          indent, func.documentationComments, _docCommentSpec);
      String argSignature = '';
      String sendArgument = 'null';
      if (func.arguments.isNotEmpty) {
        String argNameFunc(int index, NamedType type) =>
            _getSafeArgumentName(index, type);
        final Iterable<String> argExpressions =
            indexMap(func.arguments, (int index, NamedType type) {
          final String name = argNameFunc(index, type);
          if (root.enums.map((Enum e) => e.name).contains(type.type.baseName)) {
            return '$name${type.type.isNullable ? '?' : ''}.index';
          } else {
            return name;
          }
        });
        sendArgument = '<Object?>[${argExpressions.join(', ')}]';
        argSignature = _getMethodArgumentsSignature(func, argNameFunc);
      }
      indent.write(
        'Future<${_addGenericTypesNullable(func.returnType)}> ${func.name}($argSignature) async ',
      );
      indent.scoped('{', '}', () {
        final String channelName = makeChannelName(api, func);
        indent.writeln(
            'final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(');
        indent.nest(2, () {
          indent.writeln(
            "'$channelName', codec, binaryMessenger: _binaryMessenger);",
          );
        });
        final String returnType = _makeGenericTypeArguments(func.returnType);
        final String castCall = _makeGenericCastCall(func.returnType);
        const String accessor = "replyMap['${Keys.result}']";
        final String nullHandler =
            func.returnType.isNullable ? (castCall.isEmpty ? '' : '?') : '!';
        final String returnStatement = func.returnType.isVoid
            ? 'return;'
            : 'return ($accessor as $returnType?)$nullHandler$castCall;';
        indent.format('''
final Map<Object?, Object?>? replyMap =\n\t\tawait channel.send($sendArgument) as Map<Object?, Object?>?;
if (replyMap == null) {
\tthrow PlatformException(
\t\tcode: 'channel-error',
\t\tmessage: 'Unable to establish connection on channel.',
\t);
} else if (replyMap['error'] != null) {
\tfinal Map<Object?, Object?> error = (replyMap['${Keys.error}'] as Map<Object?, Object?>?)!;
\tthrow PlatformException(
\t\tcode: (error['${Keys.errorCode}'] as String?)!,
\t\tmessage: error['${Keys.errorMessage}'] as String?,
\t\tdetails: error['${Keys.errorDetails}'],
\t);''');
        // On iOS we can return nil from functions to accommodate error
        // handling.  Returning a nil value and not returning an error is an
        // exception.
        if (!func.returnType.isNullable && !func.returnType.isVoid) {
          indent.format('''
} else if (replyMap['${Keys.result}'] == null) {
\tthrow PlatformException(
\t\tcode: 'null-error',
\t\tmessage: 'Host platform returned null value for non-null return value.',
\t);''');
        }
        indent.format('''
} else {
\t$returnStatement
}''');
      });
    }
  });
}

/// Writes the code for host [Api], [api].
/// Example:
/// class FooCodec extends StandardMessageCodec {...}
///
/// abstract class Foo {
///   static const MessageCodec<Object?> codec = FooCodec();
///   int add(int x, int y);
///   static void setup(Foo api, {BinaryMessenger? binaryMessenger}) {...}
/// }
void _writeFlutterApi(
  DartOptions opt,
  Indent indent,
  Api api,
  Root root, {
  String Function(Method)? channelNameFunc,
  bool isMockHandler = false,
}) {
  assert(api.location == ApiLocation.flutter);
  String codecName = _standardMessageCodec;
  if (getCodecClasses(api, root).isNotEmpty) {
    codecName = _getCodecName(api);
    _writeCodec(indent, codecName, api, root);
  }
  addDocumentationComments(indent, api.documentationComments, _docCommentSpec);

  indent.write('abstract class ${api.name} ');
  indent.scoped('{', '}', () {
    indent.writeln('static const MessageCodec<Object?> codec = $codecName();');
    indent.addln('');
    for (final Method func in api.methods) {
      addDocumentationComments(
          indent, func.documentationComments, _docCommentSpec);

      final bool isAsync = func.isAsynchronous;
      final String returnType = isAsync
          ? 'Future<${_addGenericTypesNullable(func.returnType)}>'
          : _addGenericTypesNullable(func.returnType);
      final String argSignature = _getMethodArgumentsSignature(
        func,
        _getArgumentName,
      );
      indent.writeln('$returnType ${func.name}($argSignature);');
    }
    indent.write(
        'static void setup(${api.name}? api, {BinaryMessenger? binaryMessenger}) ');
    indent.scoped('{', '}', () {
      for (final Method func in api.methods) {
        indent.write('');
        indent.scoped('{', '}', () {
          indent.writeln(
            'final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(',
          );
          final String channelName = channelNameFunc == null
              ? makeChannelName(api, func)
              : channelNameFunc(func);
          indent.nest(2, () {
            indent.writeln(
              "'$channelName', codec, binaryMessenger: binaryMessenger);",
            );
          });
          final String messageHandlerSetter =
              isMockHandler ? 'setMockMessageHandler' : 'setMessageHandler';
          indent.write('if (api == null) ');
          indent.scoped('{', '}', () {
            indent.writeln('channel.$messageHandlerSetter(null);');
          }, addTrailingNewline: false);
          indent.add(' else ');
          indent.scoped('{', '}', () {
            indent.write(
              'channel.$messageHandlerSetter((Object? message) async ',
            );
            indent.scoped('{', '});', () {
              final String returnType =
                  _addGenericTypesNullable(func.returnType);
              final bool isAsync = func.isAsynchronous;
              final String emptyReturnStatement = isMockHandler
                  ? 'return <Object?, Object?>{};'
                  : func.returnType.isVoid
                      ? 'return;'
                      : 'return null;';
              String call;
              if (func.arguments.isEmpty) {
                indent.writeln('// ignore message');
                call = 'api.${func.name}()';
              } else {
                indent.writeln(
                  "assert(message != null, 'Argument for $channelName was null.');",
                );
                const String argsArray = 'args';
                indent.writeln(
                    'final List<Object?> $argsArray = (message as List<Object?>?)!;');
                String argNameFunc(int index, NamedType type) =>
                    _getSafeArgumentName(index, type);
                enumerate(func.arguments, (int count, NamedType arg) {
                  final String argType = _addGenericTypes(arg.type);
                  final String argName = argNameFunc(count, arg);
                  final String genericArgType =
                      _makeGenericTypeArguments(arg.type);
                  final String castCall = _makeGenericCastCall(arg.type);

                  indent.writeln(
                      'final $argType? $argName = ($argsArray[$count] as $genericArgType?)${castCall.isEmpty ? '' : '?$castCall'};');
                  if (!arg.type.isNullable) {
                    indent.writeln(
                        "assert($argName != null, 'Argument for $channelName was null, expected non-null $argType.');");
                  }
                });
                final Iterable<String> argNames =
                    indexMap(func.arguments, (int index, NamedType field) {
                  final String name = _getSafeArgumentName(index, field);
                  return '$name${field.type.isNullable ? '' : '!'}';
                });
                call = 'api.${func.name}(${argNames.join(', ')})';
              }
              if (func.returnType.isVoid) {
                if (isAsync) {
                  indent.writeln('await $call;');
                } else {
                  indent.writeln('$call;');
                }
                indent.writeln(emptyReturnStatement);
              } else {
                if (isAsync) {
                  indent.writeln('final $returnType output = await $call;');
                } else {
                  indent.writeln('final $returnType output = $call;');
                }
                const String returnExpression = 'output';
                final String returnStatement = isMockHandler
                    ? "return <Object?, Object?>{'${Keys.result}': $returnExpression};"
                    : 'return $returnExpression;';
                indent.writeln(returnStatement);
              }
            });
          });
        });
      }
    });
  });
}

/// Converts a [List] of [TypeDeclaration]s to a comma separated [String] to be
/// used in Dart code.
String _flattenTypeArguments(List<TypeDeclaration> args) {
  return args
      .map<String>((TypeDeclaration arg) => arg.typeArguments.isEmpty
          ? '${arg.baseName}?'
          : '${arg.baseName}<${_flattenTypeArguments(arg.typeArguments)}>?')
      .join(', ');
}

/// Creates the type declaration for use in Dart code from a [NamedType] making sure
/// that type arguments are used for primitive generic types.
String _addGenericTypes(TypeDeclaration type) {
  final List<TypeDeclaration> typeArguments = type.typeArguments;
  switch (type.baseName) {
    case 'List':
      return (typeArguments.isEmpty)
          ? 'List<Object?>'
          : 'List<${_flattenTypeArguments(typeArguments)}>';
    case 'Map':
      return (typeArguments.isEmpty)
          ? 'Map<Object?, Object?>'
          : 'Map<${_flattenTypeArguments(typeArguments)}>';
    default:
      return type.baseName;
  }
}

String _addGenericTypesNullable(TypeDeclaration type) {
  final String genericdType = _addGenericTypes(type);
  return type.isNullable ? '$genericdType?' : genericdType;
}

/// Generates Dart source code for the given AST represented by [root],
/// outputting the code to [sink].
void generateDart(DartOptions opt, Root root, StringSink sink) {
  final List<String> customClassNames =
      root.classes.map((Class x) => x.name).toList();
  final List<String> customEnumNames =
      root.enums.map((Enum x) => x.name).toList();
  final Indent indent = Indent(sink);

  void writeHeader() {
    if (opt.copyrightHeader != null) {
      addLines(indent, opt.copyrightHeader!, linePrefix: '// ');
    }
    indent.writeln('// $generatedCodeWarning');
    indent.writeln('// $seeAlsoWarning');
    indent.writeln(
      '// ignore_for_file: public_member_api_docs, non_constant_identifier_names, avoid_as, unused_import, unnecessary_parenthesis, prefer_null_aware_operators, omit_local_variable_types, unused_shown_name, unnecessary_import',
    );
  }

  void writeEnums() {
    for (final Enum anEnum in root.enums) {
      indent.writeln('');
      addDocumentationComments(
          indent, anEnum.documentationComments, _docCommentSpec);
      indent.write('enum ${anEnum.name} ');
      indent.scoped('{', '}', () {
        for (final String member in anEnum.members) {
          indent.writeln('$member,');
        }
      });
    }
  }

  void writeImports() {
    indent.writeln("import 'dart:async';");
    indent.writeln(
      "import 'dart:typed_data' show Float64List, Int32List, Int64List, Uint8List;",
    );
    indent.addln('');
    indent.writeln(
        "import 'package:flutter/foundation.dart' show ReadBuffer, WriteBuffer;");
    indent.writeln("import 'package:flutter/services.dart';");
  }

  void writeDataClass(Class klass) {
    void writeConstructor() {
      indent.write(klass.name);
      indent.scoped('({', '});', () {
        for (final NamedType field in klass.fields) {
          final String required = field.type.isNullable ? '' : 'required ';
          indent.writeln('${required}this.${field.name},');
        }
      });
    }

    void writeEncode() {
      indent.write('Object encode() ');
      indent.scoped('{', '}', () {
        indent.writeln(
          'final Map<Object?, Object?> pigeonMap = <Object?, Object?>{};',
        );
        for (final NamedType field in klass.fields) {
          indent.write("pigeonMap['${field.name}'] = ");
          final String conditional = field.type.isNullable ? '?' : '';
          if (customClassNames.contains(field.type.baseName)) {
            indent.addln(
              '${field.name}$conditional.encode();',
            );
          } else if (customEnumNames.contains(field.type.baseName)) {
            indent.addln(
              '${field.name}$conditional.index;',
            );
          } else {
            indent.addln('${field.name};');
          }
        }
        indent.writeln('return pigeonMap;');
      });
    }

    void writeDecode() {
      void writeValueDecode(NamedType field) {
        if (customClassNames.contains(field.type.baseName)) {
          final String nonNullValue =
              "${field.type.baseName}.decode(pigeonMap['${field.name}']!)";
          indent.format(
              field.type.isNullable
                  ? '''
pigeonMap['${field.name}'] != null
\t\t? $nonNullValue
\t\t: null'''
                  : nonNullValue,
              leadingSpace: false,
              trailingNewline: false);
        } else if (customEnumNames.contains(field.type.baseName)) {
          final String nonNullValue =
              "${field.type.baseName}.values[pigeonMap['${field.name}']! as int]";
          indent.format(
              field.type.isNullable
                  ? '''
pigeonMap['${field.name}'] != null
\t\t? $nonNullValue
\t\t: null'''
                  : nonNullValue,
              leadingSpace: false,
              trailingNewline: false);
        } else if (field.type.typeArguments.isNotEmpty) {
          final String genericType = _makeGenericTypeArguments(field.type);
          final String castCall = _makeGenericCastCall(field.type);
          final String castCallPrefix = field.type.isNullable ? '?' : '!';
          indent.add(
            "(pigeonMap['${field.name}'] as $genericType?)$castCallPrefix$castCall",
          );
        } else {
          final String genericdType = _addGenericTypesNullable(field.type);
          if (field.type.isNullable) {
            indent.add(
              "pigeonMap['${field.name}'] as $genericdType",
            );
          } else {
            indent.add(
              "pigeonMap['${field.name}']! as $genericdType",
            );
          }
        }
      }

      indent.write(
        'static ${klass.name} decode(Object message) ',
      );
      indent.scoped('{', '}', () {
        indent.writeln(
          'final Map<Object?, Object?> pigeonMap = message as Map<Object?, Object?>;',
        );
        indent.write('return ${klass.name}');
        indent.scoped('(', ');', () {
          for (int index = 0; index < klass.fields.length; index += 1) {
            final NamedType field = klass.fields[index];
            indent.write('${field.name}: ');
            writeValueDecode(field);
            indent.addln(',');
          }
        });
      });
    }

    addDocumentationComments(
        indent, klass.documentationComments, _docCommentSpec);

    indent.write('class ${klass.name} ');
    indent.scoped('{', '}', () {
      writeConstructor();
      indent.addln('');
      for (final NamedType field in klass.fields) {
        addDocumentationComments(
            indent, field.documentationComments, _docCommentSpec);

        final String datatype = _addGenericTypesNullable(field.type);
        indent.writeln('$datatype ${field.name};');
      }
      if (klass.fields.isNotEmpty) {
        indent.writeln('');
      }
      writeEncode();
      indent.writeln('');
      writeDecode();
    });
  }

  void writeApi(Api api) {
    if (api.location == ApiLocation.host) {
      _writeHostApi(opt, indent, api, root);
    } else if (api.location == ApiLocation.flutter) {
      _writeFlutterApi(opt, indent, api, root);
    }
  }

  writeHeader();
  writeImports();
  writeEnums();
  for (final Class klass in root.classes) {
    indent.writeln('');
    writeDataClass(klass);
  }
  for (final Api api in root.apis) {
    indent.writeln('');
    writeApi(api);
  }
}

/// Crawls up the path of [dartFilePath] until it finds a pubspec.yaml in a
/// parent directory and returns its path.
String? _findPubspecPath(String dartFilePath) {
  try {
    Directory dir = File(dartFilePath).parent;
    String? pubspecPath;
    while (pubspecPath == null) {
      if (dir.existsSync()) {
        final Iterable<String> pubspecPaths = dir
            .listSync()
            .map((FileSystemEntity e) => e.path)
            .where((String path) => path.endsWith('pubspec.yaml'));
        if (pubspecPaths.isNotEmpty) {
          pubspecPath = pubspecPaths.first;
        } else {
          dir = dir.parent;
        }
      } else {
        break;
      }
    }
    return pubspecPath;
  } catch (ex) {
    return null;
  }
}

/// Given the path of a Dart file, [mainDartFile], the name of the package will
/// be deduced by locating and parsing its associated pubspec.yaml.
String? _deducePackageName(String mainDartFile) {
  final String? pubspecPath = _findPubspecPath(mainDartFile);
  if (pubspecPath == null) {
    return null;
  }

  try {
    final String text = File(pubspecPath).readAsStringSync();
    return (yaml.loadYaml(text) as Map<dynamic, dynamic>)['name'] as String?;
  } catch (_) {
    return null;
  }
}

/// Converts [inputPath] to a posix absolute path.
String _posixify(String inputPath) {
  final path.Context context = path.Context(style: path.Style.posix);
  return context.fromUri(path.toUri(path.absolute(inputPath)));
}

/// Generates Dart source code for test support libraries based on the given AST
/// represented by [root], outputting the code to [sink]. [dartOutPath] is the
/// path of the generated dart code to be tested. [testOutPath] is where the
/// test code will be generated.
void generateTestDart(
  DartOptions opt,
  Root root,
  StringSink sink, {
  required String dartOutPath,
  required String testOutPath,
}) {
  final Indent indent = Indent(sink);
  if (opt.copyrightHeader != null) {
    addLines(indent, opt.copyrightHeader!, linePrefix: '// ');
  }
  indent.writeln('// $generatedCodeWarning');
  indent.writeln('// $seeAlsoWarning');
  indent.writeln(
    '// ignore_for_file: public_member_api_docs, non_constant_identifier_names, avoid_as, unused_import, unnecessary_parenthesis, unnecessary_import',
  );
  indent.writeln('// ignore_for_file: avoid_relative_lib_imports');
  indent.writeln("import 'dart:async';");
  indent.writeln(
    "import 'dart:typed_data' show Float64List, Int32List, Int64List, Uint8List;",
  );
  indent.writeln(
      "import 'package:flutter/foundation.dart' show ReadBuffer, WriteBuffer;");
  indent.writeln("import 'package:flutter/services.dart';");
  indent.writeln("import 'package:flutter_test/flutter_test.dart';");
  indent.writeln('');
  final String relativeDartPath =
      path.Context(style: path.Style.posix).relative(
    _posixify(dartOutPath),
    from: _posixify(path.dirname(testOutPath)),
  );
  late final String? packageName = _deducePackageName(dartOutPath);
  if (!relativeDartPath.contains('/lib/') || packageName == null) {
    // If we can't figure out the package name or the relative path doesn't
    // include a 'lib' directory, try relative path import which only works in
    // certain (older) versions of Dart.
    // TODO(gaaclarke): We should add a command-line parameter to override this import.
    indent.writeln(
        "import '${_escapeForDartSingleQuotedString(relativeDartPath)}';");
  } else {
    final String path = relativeDartPath.replaceFirst(RegExp(r'^.*/lib/'), '');
    indent.writeln("import 'package:$packageName/$path';");
  }
  for (final Api api in root.apis) {
    if (api.location == ApiLocation.host && api.dartHostTestHandler != null) {
      final Api mockApi = Api(
        name: api.dartHostTestHandler!,
        methods: api.methods,
        location: ApiLocation.flutter,
        dartHostTestHandler: api.dartHostTestHandler,
        documentationComments: api.documentationComments,
      );
      indent.writeln('');
      _writeFlutterApi(
        opt,
        indent,
        mockApi,
        root,
        channelNameFunc: (Method func) => makeChannelName(api, func),
        isMockHandler: true,
      );
    }
  }
}
