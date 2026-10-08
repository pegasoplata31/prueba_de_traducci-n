// ============================================================
//  ml_kit_translator.dart
//  Traducción OFFLINE con Google ML Kit On-Device Translation.
//
//  - Descarga modelos dinámicamente (~30 MB por idioma).
//  - Después de descargados, funciona SIN internet.
//  - Requiere atribución "Traducido por Google" en la UI.
// ============================================================

import 'dart:async';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Resultado de una operación de traducción.
class MlTranslationResult {
  final String text;
  final bool success;
  final String? error;
  final bool fromModelJustDownloaded;

  MlTranslationResult({
    required this.text,
    this.success = true,
    this.error,
    this.fromModelJustDownloaded = false,
  });

  static MlTranslationResult failure(String error) =>
      MlTranslationResult(text: '', success: false, error: error);
}

/// Gestor de traducción offline con ML Kit.
class MlKitTranslator {
  /// Mapa: código de la app → código BCP-47 de ML Kit.
  ///
  /// ⚠️ ML Kit NO tiene cantonés ni variantes regionales de español.
  /// Por eso:
  ///   - zh-yue (cantonés) → zh (chino simplificado)
  ///   - es-PA, es-MX, es-ES → es (español genérico)
  static const Map<String, String> langMap = {
    'zh-yue': 'zh',
    'zh-cmn': 'zh',
    'es-PA': 'es',
    'es-MX': 'es',
    'es-ES': 'es',
    'pt': 'pt',
    'en': 'en',
    'fr': 'fr',
    'de': 'de',
    'ar': 'ar',
    'ru': 'ru',
    'ja': 'ja',
    'ko': 'ko',
  };

  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();

  OnDeviceTranslator? _translator;
  String? _currentSource;
  String? _currentTarget;

  /// Idiomas que se precargan al primer arranque.
  /// Español + inglés cubren el caso más común (origen y destino).
  static const List<String> preloadLanguages = ['es-PA', 'en'];

  // ---------------------------------------------------------
  //  Gestión de modelos
  // ---------------------------------------------------------

  /// Verifica si el modelo de un idioma ya está descargado.
  Future<bool> isModelDownloaded(String appLangCode) async {
    final bcp = langMap[appLangCode] ?? appLangCode;
    try {
      return await _modelManager.isModelDownloaded(bcp);
    } catch (_) {
      return false;
    }
  }

  /// Descarga el modelo de un idioma.
  /// [onProgress] recibe 0.0 al inicio y 1.0 al terminar.
  /// ⚠️ ML Kit no expone progreso granular: reportamos 0 → 1.
  Future<bool> downloadModel(
    String appLangCode, {
    void Function(double progress)? onProgress,
  }) async {
    final bcp = langMap[appLangCode] ?? appLangCode;

    // Si ya está descargado, no hacemos nada.
    if (await isModelDownloaded(appLangCode)) {
      onProgress?.call(1.0);
      return true;
    }

    onProgress?.call(0.0);
    try {
      final result = await _modelManager.downloadModel(bcp);
      onProgress?.call(1.0);
      return result;
    } catch (_) {
      return false;
    }
  }

  /// Precarga los modelos iniciales (español + inglés).
  /// [onProgress] recibe (done, total) para mostrar barra global.
  Future<void> preloadInitialModels({
    void Function(int done, int total)? onProgress,
  }) async {
    int done = 0;
    for (final code in preloadLanguages) {
      await downloadModel(code);
      done++;
      onProgress?.call(done, preloadLanguages.length);
    }
  }

  /// Descarga los modelos de una lista de idiomas (usado al cambiar idioma).
  Future<void> preloadAll(
    List<String> appLangCodes, {
    void Function(int done, int total)? onProgress,
  }) async {
    int done = 0;
    for (final code in appLangCodes) {
      await downloadModel(code);
      done++;
      onProgress?.call(done, appLangCodes.length);
    }
  }

  // ---------------------------------------------------------
  //  Traducción
  // ---------------------------------------------------------

  /// Traduce un texto. Reutiliza el traductor si el par no cambió.
  Future<MlTranslationResult> translate(
    String text, {
    String fromLang = 'es-PA',
    required String toLang,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return MlTranslationResult(text: trimmed);
    }

    // Si el idioma de origen y destino son el mismo (ej. es-PA → es-MX),
    // no hace falta traducir.
    final fromBcp = langMap[fromLang] ?? fromLang;
    final toBcp = langMap[toLang] ?? toLang;
    if (fromBcp == toBcp) {
      return MlTranslationResult(text: trimmed);
    }

    // Verificar que el modelo esté descargado.
    final sourceOk = await isModelDownloaded(fromLang);
    final targetOk = await isModelDownloaded(toLang);
    if (!sourceOk || !targetOk) {
      return MlTranslationResult.failure(
        'Modelo no descargado ($fromBcp/$toBcp)',
      );
    }

    // Reutilizar traductor si el par no cambió.
    if (_translator != null &&
        _currentSource == fromBcp &&
        _currentTarget == toBcp) {
      try {
        final out = await _translator!.translateText(trimmed);
        return MlTranslationResult(text: out);
      } catch (e) {
        return MlTranslationResult.failure('Error: $e');
      }
    }

    // Crear nuevo traductor.
    await _translator?.close();
    _translator = OnDeviceTranslator(
      sourceLanguage: _parseLang(fromBcp),
      targetLanguage: _parseLang(toBcp),
    );
    _currentSource = fromBcp;
    _currentTarget = toBcp;

    try {
      final out = await _translator!.translateText(trimmed);
      return MlTranslationResult(text: out);
    } catch (e) {
      return MlTranslationResult.failure('Error: $e');
    }
  }

  /// Traduce una lista de palabras al idioma destino.
  /// Devuelve un mapa { palabraOriginal → traducción }.
  Future<Map<String, String>> translateBatch(
    List<String> words, {
    String fromLang = 'es-PA',
    required String toLang,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = <String, String>{};
    int done = 0;

    for (final word in words) {
      final r = await translate(word, fromLang: fromLang, toLang: toLang);
      result[word] = r.success ? r.text : word;
      done++;
      onProgress?.call(done, words.length);
    }

    return result;
  }

  /// Convierte un código BCP-47 a TranslateLanguage de ML Kit.
  TranslateLanguage _parseLang(String bcpCode) {
    return TranslateLanguage.values.firstWhere(
      (l) => l.bcpCode == bcpCode || l.bcpCode.startsWith('$bcpCode-'),
      orElse: () => TranslateLanguage.english,
    );
  }

  /// Libera recursos.
  Future<void> dispose() async {
    await _translator?.close();
    _translator = null;
  }
}
