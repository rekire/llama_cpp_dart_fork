import 'dart:ffi';
import 'dart:io';
import 'dart:async';

import 'package:ffi/ffi.dart';
import 'sampler_params.dart';
import 'model_params.dart';
import 'llama_cpp.dart';
import 'context_params.dart';

/// Custom exception for Llama-specific errors
class LlamaException implements Exception {
  final String message;
  final dynamic originalError;

  LlamaException(this.message, [this.originalError]);

  @override
  String toString() =>
      'LlamaException: $message${originalError != null ? ' ($originalError)' : ''}';
}

/// Status tracking for the Llama instance
enum LlamaStatus { uninitialized, ready, generating, error, disposed }

/// A Dart wrapper for llama.cpp functionality.
/// Provides text generation capabilities using the llama model.
class Llama {
  static llama_cpp? _lib;
  Pointer<llama_model>? model;
  Pointer<llama_context>? context;
  llama_batch? batch;

  Pointer<llama_sampler> _smpl = nullptr;
  Pointer<llama_token> _tokens = nullptr;
  Pointer<llama_token> _tokenPtr = nullptr;
  int _nPrompt = 0;
  int _nPredict = 32;
  int _nPos = 0;

  // bool _isInitialized = false;
  bool _isDisposed = false;
  LlamaStatus _status = LlamaStatus.uninitialized;

  static String? libraryPath = switch(Platform.operatingSystem) {
    'android' || 'linux' => 'libllama.so',
    'windows' => 'llama.dll',
    'ios' || 'macos' => 'libllama.dylib',
    _ => null
  };

  /// Gets the current status of the Llama instance
  LlamaStatus get status => _status;

  /// Checks if the instance has been disposed
  bool get isDisposed => _isDisposed;

  static llama_cpp get lib {
    if (_lib == null) {
      if (libraryPath != null) {
        _lib = llama_cpp(DynamicLibrary.open(libraryPath!));
      } else {
        _lib = llama_cpp(DynamicLibrary.process());
      }
    }
    return _lib!;
  }

  /// Creates a new Llama instance with the specified model path and optional parameters.
  ///
  /// Throws [LlamaException] if model loading or initialization fails.
  Llama(String modelPath,
      [ModelParams? modelParamsDart,
      ContextParams? contextParamsDart,
      SamplerParams? samplerParams]) {
    try {
      _validateConfiguration();
      _initializeLlama(
          modelPath, modelParamsDart, contextParamsDart, samplerParams);
      // _isInitialized = true;
      _status = LlamaStatus.ready;

      // ggml_log_callback logCallback = nullptr;
      // lib.llama_log_set(logCallback, nullptr);
    } catch (e) {
      _status = LlamaStatus.error;
      dispose();
      throw LlamaException('Failed to initialize Llama', e);
    }
  }

  /// Validates the configuration parameters
  void _validateConfiguration() {
    if (_nPredict <= 0) {
      throw ArgumentError('nPredict must be positive');
    }
  }

  /// Initializes the Llama instance with the given parameters
  void _initializeLlama(String modelPath, ModelParams? modelParamsDart,
      ContextParams? contextParamsDart, SamplerParams? samplerParams) {
    lib.llama_backend_init();

    modelParamsDart ??= ModelParams();
    var modelParams = modelParamsDart.get();

    final modelPathPtr = modelPath.toNativeUtf8().cast<Char>();
    try {
      model = lib.llama_load_model_from_file(modelPathPtr, modelParams);
      if (model!.address == 0) {
        throw LlamaException("Could not load model at $modelPath");
      }
    } finally {
      malloc.free(modelPathPtr);
    }

    contextParamsDart ??= ContextParams();
    _nPredict = contextParamsDart.nPredit;
    var contextParams = contextParamsDart.get();

    context = lib.llama_new_context_with_model(model!, contextParams);
    if (context!.address == 0) {
      throw Exception("Could not load context!");
    }

    samplerParams ??= SamplerParams();

    // Initialize sampler chain
    llama_sampler_chain_params sparams =
        lib.llama_sampler_chain_default_params();
    sparams.no_perf = false;
    _smpl = lib.llama_sampler_chain_init(sparams);

    // Add samplers based on params
    if (samplerParams.greedy) {
      lib.llama_sampler_chain_add(_smpl, lib.llama_sampler_init_greedy());
    }

    lib.llama_sampler_chain_add(
        _smpl, lib.llama_sampler_init_dist(samplerParams.seed));

    if (samplerParams.softmax) {
      lib.llama_sampler_chain_add(_smpl, lib.llama_sampler_init_softmax());
    }

    lib.llama_sampler_chain_add(
        _smpl, lib.llama_sampler_init_top_k(samplerParams.topK));
    lib.llama_sampler_chain_add(
        _smpl,
        lib.llama_sampler_init_top_p(
            samplerParams.topP, samplerParams.topPKeep));
    lib.llama_sampler_chain_add(
        _smpl,
        lib.llama_sampler_init_min_p(
            samplerParams.minP, samplerParams.minPKeep));
    lib.llama_sampler_chain_add(
        _smpl,
        lib.llama_sampler_init_typical(
            samplerParams.typical, samplerParams.typicalKeep));
    lib.llama_sampler_chain_add(
        _smpl, lib.llama_sampler_init_temp(samplerParams.temp));
    lib.llama_sampler_chain_add(
        _smpl,
        lib.llama_sampler_init_xtc(
            samplerParams.xtcTemperature,
            samplerParams.xtcStartValue,
            samplerParams.xtcKeep,
            samplerParams.xtcLength));

    lib.llama_sampler_chain_add(
        _smpl,
        lib.llama_sampler_init_mirostat(
            lib.llama_n_vocab(model!),
            samplerParams.seed,
            samplerParams.mirostatTau,
            samplerParams.mirostatEta,
            samplerParams.mirostatM));

    lib.llama_sampler_chain_add(
        _smpl,
        lib.llama_sampler_init_mirostat_v2(samplerParams.seed,
            samplerParams.mirostat2Tau, samplerParams.mirostat2Eta));

    final grammarStrPtr = samplerParams.grammarStr.toNativeUtf8().cast<Char>();
    final grammarRootPtr =
        samplerParams.grammarRoot.toNativeUtf8().cast<Char>();
    lib.llama_sampler_chain_add(_smpl,
        lib.llama_sampler_init_grammar(model!, grammarStrPtr, grammarRootPtr));
    calloc.free(grammarStrPtr);
    calloc.free(grammarRootPtr);

    lib.llama_sampler_chain_add(
        _smpl,
        lib.llama_sampler_init_penalties(
            lib.llama_n_vocab(model!),
            lib.llama_token_eos(model!),
            lib.llama_token_nl(model!),
            samplerParams.penaltyLastTokens,
            samplerParams.penaltyRepeat,
            samplerParams.penaltyFreq,
            samplerParams.penaltyPresent,
            samplerParams.penaltyNewline,
            samplerParams.ignoreEOS));

    // Add DRY sampler
    final seqBreakers = samplerParams.dryBreakers;
    final numBreakers = seqBreakers.length;
    final seqBreakersPointer = calloc<Pointer<Char>>(numBreakers);

    try {
      for (var i = 0; i < numBreakers; i++) {
        seqBreakersPointer[i] = seqBreakers[i].toNativeUtf8().cast<Char>();
      }

      lib.llama_sampler_chain_add(
          _smpl,
          lib.llama_sampler_init_dry(
              model!,
              samplerParams.dryPenalty,
              samplerParams.dryMultiplier,
              samplerParams.dryAllowedLen,
              samplerParams.dryLookback,
              seqBreakersPointer,
              numBreakers));
    } finally {
      // Clean up DRY sampler allocations
      for (var i = 0; i < numBreakers; i++) {
        calloc.free(seqBreakersPointer[i]);
      }
      calloc.free(seqBreakersPointer);
    }

    // lib.llama_sampler_chain_add(_smpl, lib.llama_sampler_init_infill(model));

    _tokenPtr = malloc<llama_token>();
  }

  /// Sets the prompt for text generation.
  ///
  /// [prompt] - The input prompt text
  /// [onProgress] - Optional callback for tracking tokenization progress
  ///
  /// Throws [ArgumentError] if prompt is empty
  /// Throws [LlamaException] if tokenization fails
  void setPrompt(String prompt,
      {void Function(int current, int total)? onProgress}) {
    if (prompt.isEmpty) {
      throw ArgumentError('Prompt cannot be empty');
    }
    if (_isDisposed) {
      throw StateError('Cannot set prompt on disposed instance');
    }

    try {
      _status = LlamaStatus.generating;

      // Free previous tokens if they exist
      if (_tokens != nullptr) {
        malloc.free(_tokens);
      }

      final promptPtr = prompt.toNativeUtf8().cast<Char>();
      try {
        _nPrompt = -lib.llama_tokenize(
            model!, promptPtr, prompt.length, nullptr, 0, true, true);

        _tokens = malloc<llama_token>(_nPrompt);
        if (lib.llama_tokenize(model!, promptPtr, prompt.length, _tokens,
                _nPrompt, true, true) <
            0) {
          throw LlamaException("Failed to tokenize prompt");
        }

        batch = lib.llama_batch_get_one(_tokens, _nPrompt);
        _nPos = 0;
      } finally {
        malloc.free(promptPtr);
      }
    } catch (e) {
      _status = LlamaStatus.error;
      throw LlamaException('Error setting prompt', e);
    }
  }

  /// Generates the next token in the sequence.
  ///
  /// Returns a tuple containing the generated text and a boolean indicating if generation is complete.
  /// Throws [LlamaException] if generation fails.
  (String, bool) getNext() {
    if (_isDisposed) {
      throw StateError('Cannot generate text on disposed instance');
    }

    try {
      if (_nPos + batch!.n_tokens >= _nPrompt + _nPredict) {
        return ("", true);
      }

      if (lib.llama_decode(context!, batch!) != 0) {
        throw LlamaException("Failed to eval");
      }

      _nPos += batch!.n_tokens;

      int newTokenId = lib.llama_sampler_sample(_smpl, context!, -1);

      if (lib.llama_token_is_eog(model!, newTokenId)) {
        return ("", true);
      }

      final buf = malloc<Char>(128);
      try {
        int n = lib.llama_token_to_piece(model!, newTokenId, buf, 128, 0, true);
        if (n < 0) {
          throw LlamaException("Failed to convert token to piece");
        }

        String piece = String.fromCharCodes(buf.cast<Uint8>().asTypedList(n));

        _tokenPtr.value = newTokenId;
        batch = lib.llama_batch_get_one(_tokenPtr, 1);

        bool isEos = newTokenId == lib.llama_token_eos(model!);
        return (piece, isEos);
      } finally {
        malloc.free(buf);
      }
    } catch (e) {
      _status = LlamaStatus.error;
      throw LlamaException('Error generating text', e);
    }
  }

  /// Provides a stream of generated text tokens
  Stream<String> generateText() async* {
    if (_isDisposed) {
      throw StateError('Cannot generate text on disposed instance');
    }

    try {
      while (true) {
        final (text, isDone) = getNext();
        if (isDone) break;
        yield text;
      }
    } catch (e) {
      _status = LlamaStatus.error;
      throw LlamaException('Error in text generation stream', e);
    }
  }

  /// Disposes of all resources held by this instance
  void dispose() {
    if (_isDisposed) return;

    if (_tokens != nullptr) malloc.free(_tokens);
    if (_tokenPtr != nullptr) malloc.free(_tokenPtr);
    if (_smpl != nullptr) lib.llama_sampler_free(_smpl);
    if (context?.address != 0) lib.llama_free(context!);
    if (model?.address != 0) lib.llama_free_model(model!);

    lib.llama_backend_free();

    _isDisposed = true;
    _status = LlamaStatus.disposed;
  }

  /// Clears the current state of the Llama instance
  /// This allows reusing the same instance for a new generation
  /// without creating a new instance
  void clear() {
    if (_isDisposed) {
      throw StateError('Cannot clear disposed instance');
    }

    try {
      // Free current tokens if they exist
      if (_tokens != nullptr) {
        malloc.free(_tokens);
        _tokens = nullptr;
      }

      // Reset internal state
      _nPrompt = 0;
      _nPos = 0;

      // Reset the context state
      if (context?.address != 0) {
        lib.llama_kv_cache_clear(context!);
      }

      // Reset batch
      batch = lib.llama_batch_init(0, 0, 1);

      _status = LlamaStatus.ready;
    } catch (e) {
      _status = LlamaStatus.error;
      throw LlamaException('Failed to clear Llama state', e);
    }
  }

  /// Converts a text string to a list of token IDs
  ///
  /// [text] - The input text to tokenize
  /// [addBos] - Whether to add the beginning-of-sequence token
  ///
  /// Returns a List of integer token IDs
  ///
  /// Throws [ArgumentError] if text is empty
  /// Throws [LlamaException] if tokenization fails
  List<int> tokenize(String text, bool addBos) {
    if (_isDisposed) {
      throw StateError('Cannot tokenize with disposed instance');
    }

    if (text.isEmpty) {
      throw ArgumentError('Text cannot be empty');
    }

    try {
      final textPtr = text.toNativeUtf8().cast<Char>();

      try {
        // First get the required number of tokens
        int nTokens = -lib.llama_tokenize(
            model!, textPtr, text.length, nullptr, 0, addBos, true);

        if (nTokens <= 0) {
          throw LlamaException('Failed to determine token count');
        }

        // Allocate token array
        final tokens = malloc<llama_token>(nTokens);

        try {
          // Perform actual tokenization
          int actualTokens = lib.llama_tokenize(
              model!, textPtr, text.length, tokens, nTokens, addBos, true);

          if (actualTokens < 0) {
            throw LlamaException('Tokenization failed');
          }

          // Convert to Dart list
          return List<int>.generate(actualTokens, (i) => tokens[i]);
        } finally {
          malloc.free(tokens);
        }
      } finally {
        malloc.free(textPtr);
      }
    } catch (e) {
      throw LlamaException('Error during tokenization', e);
    }
  }
}
