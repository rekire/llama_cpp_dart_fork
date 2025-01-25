import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

void main() {
  test('Smoke-Test', () {
    String modelPath = 'Oolel-Small-v0.1.Q4_K_S.gguf';
    Llama llama = Llama(modelPath);

    llama.setPrompt('Tell me a joke');
    var answer = '';
    while (true) {
      var (token, done) = llama.getNext();
      answer += token;
      if (done) break;
    }
    stdout.write('Answer: $answer\n');

    llama.dispose();
  });
}
