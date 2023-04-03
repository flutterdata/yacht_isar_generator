import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:isar_generator/src/collection_generator.dart';
import 'package:source_gen/source_gen.dart';
import 'package:isar_generator/src/code_gen/collection_schema_generator.dart';
import 'package:isar_generator/src/code_gen/query_distinct_by_generator.dart';
import 'package:isar_generator/src/code_gen/query_filter_generator.dart';
import 'package:isar_generator/src/code_gen/query_object_generator.dart';
import 'package:isar_generator/src/code_gen/query_sort_by_generator.dart';
import 'package:isar_generator/src/code_gen/query_where_generator.dart';
import 'package:isar_generator/src/code_gen/type_adapter_generator.dart';
import 'package:yacht/yacht.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:yacht_isar_generator/src/yacht_isar_analyzer.dart';

Builder repositoryBuilder(options) => SharedPartBuilder([
      RepositoryGenerator(),
      IsarEmbeddedGenerator(),
    ], 'yacht');

class RepositoryGenerator extends GeneratorForAnnotation<DataRepository> {
  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    final className = element.name!;
    final classNameLower = className.decapitalize().pluralize();
    final classNamePlural = className.toString().pluralize();
    ClassElement classElement = element as ClassElement;

    final mixins = annotation.read('adapters').listValue.map((obj) {
      final mixinType = obj.toTypeValue() as ParameterizedType;
      final args = mixinType.typeArguments;

      if (args.length > 1) {
        throw UnsupportedError(
            'LocalAdapter `$mixinType` MUST have at most one type argument (T extends DataModel<T>) is supported for $mixinType');
      }

      final mixinElement = mixinType.element as MixinElement;
      final instantiatedMixinType = mixinElement.instantiate(
        typeArguments: [if (args.isNotEmpty) element.thisType],
        nullabilitySuffix: NullabilitySuffix.none,
      );
      return instantiatedMixinType.getDisplayString(withNullability: false);
    });

    // relationship-related

    final relationships = classElement.relationshipFields
        .fold<Set<Map<String, String?>>>({}, (result, field) {
      final relationshipClassElement = field.typeElement;

      final relationshipAnnotation = TypeChecker.fromRuntime(DataRelationship)
          .firstAnnotationOfExact(field, throwOnUnresolved: false);
      final jsonKeyAnnotation = TypeChecker.fromUrl(
              'package:json_annotation/json_annotation.dart#JsonKey')
          .firstAnnotationOfExact(field, throwOnUnresolved: false);

      final jsonKeyIgnored =
          jsonKeyAnnotation?.getField('ignore')?.toBoolValue() ?? false;

      if (jsonKeyIgnored) {
        throw UnsupportedError('''
@JsonKey(ignore: true) is not allowed in Flutter Data relationships.

Please use @DataRelationship(serialized: false) to prevent it from
serializing and deserializing.
''');
      }

      // define inverse

      var inverse =
          relationshipAnnotation?.getField('inverse')?.toStringValue();

      if (inverse == null) {
        final possibleInverseElements =
            relationshipClassElement.relationshipFields.where((elem) {
          return (elem.type as ParameterizedType)
                  .typeArguments
                  .single
                  .element ==
              classElement;
        });

        if (possibleInverseElements.length > 1) {
          throw UnsupportedError('''
Too many possible inverses for relationship `${field.name}`
of type $className: ${possibleInverseElements.map((e) => e.name).join(', ')}

Please specify the correct inverse in the $className class, for example:

@DataRelationship(inverse: '${possibleInverseElements.first.name}')
final BelongsTo<${relationshipClassElement.name}> ${field.name};

and execute a code generation build again.
''');
        } else if (possibleInverseElements.length == 1) {
          inverse = possibleInverseElements.single.name;
        }
      }

      // prepare metadata

      result.add({
        'key': field.name,
        'name': field.name,
        'inverseName': inverse,
        'type': relationshipClassElement.name,
      });

      return result;
    }).toList();

    final relationshipMeta = {
      for (final rel in relationships)
        '\'${rel['key']}\'': '''RelationshipMeta<${rel['type']}>(
            name: '${rel['name']}',
            ${rel['inverseName'] != null ? 'inverseName: \'${rel['inverseName']}\',' : ''}
            type: '${rel['type']}',
            instance: (_) => (_ as $className).${rel['name']},
          )''',
    };

    // isar shit
    final object = YachtIsarAnalyzer().analyzeCollection(element);

    return '''
// coverage:ignore-file
// ignore_for_file: ${ignoreLints.join(', ')}

mixin \$${className}Adapter on Repository<$className> {
  @override
  get schema => ${className}Schema;

  static final Map<String, RelationshipMeta> _k${className}RelationshipMetas = 
    $relationshipMeta;

  @override
  Map<String, RelationshipMeta> get relationshipMetas => _k${className}RelationshipMetas;
}

class ${classNamePlural}Repository = Repository<$className> with \$${className}Adapter${mixins.map((e) => ', $e').join()};

//

final ${classNameLower}RepositoryProvider =
    Provider<Repository<$className>>((ref) => ${classNamePlural}Repository(ref));

extension ProviderContainer${className}X on ProviderContainer {
  Repository<$className> get $classNameLower => read(${classNameLower}RepositoryProvider);
}

// isar

${generateSchema(object)}

${generateEstimateSerialize(object)}
${generateSerialize(object)}
${generateDeserialize(object)}
${generateDeserializeProp(object)}

${generateEnumMaps(object)}

${generateGetId(object)}
${generateGetLinks(object)}
${generateAttach(object)}

${WhereGenerator(object).generate()}
${FilterGenerator(object).generate()}
${generateQueryObjects(object)}

${generateSortBy(object)}
${generateDistinctBy(object)}
''';
  }
}

// extensions

final relationshipTypeChecker = TypeChecker.fromRuntime(Relationship);

extension ClassElementX on ClassElement {
  // unique collection of constructor arguments and fields
  Iterable<VariableElement> get relationshipFields {
    Map<String, VariableElement> map;

    map = {
      for (final field in fields)
        if (field.type.element is ClassElement &&
            field.isPublic &&
            (field.type.element as ClassElement).supertype != null &&
            relationshipTypeChecker.isSuperOf(field.type.element!))
          field.name: field,
    };

    return map.values.toList();
  }
}

extension VariableElementX on VariableElement {
  ClassElement get typeElement =>
      (type as ParameterizedType).typeArguments.single.element as ClassElement;
}
