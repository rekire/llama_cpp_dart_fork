import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

void main() {
  test('Smoke-Test', () {
    final found = Llama.libraryPath != null && File(Llama.libraryPath!).existsSync();
    print('Using libraryPath: ${Llama.libraryPath} found: $found');
    print('Current path: ${Directory.current.path}');

    String modelPath = 'Oolel-Small-v0.1.Q4_K_S.gguf';
    Llama llama = Llama(modelPath);

    llama.setPrompt('Tell me a joke');
    var answer = '';
    while (true) {
      var (token, done) = llama.getNext();
      answer += token;
      if (done) break;
    }
    print('Joke: $answer');

    llama.dispose();
  });
}
