import 'package:flutter/material.dart';

class Greeting extends StatelessWidget {
  const Greeting({super.key});

  @override
  Widget build(BuildContext context) {
    print('Building greeting');
    return const Text('Hello Bangkok');
  }
}
