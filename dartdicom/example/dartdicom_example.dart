import 'package:dartdicom/dartdicom.dart';

void main() {
  const tag = Tag.of(0x0010, 0x0010); // (0010,0010) Patient's Name
  String hex(int n) => n.toRadixString(16).padLeft(4, '0').toUpperCase();
  print('(${hex(tag.group)},${hex(tag.element)}) private: ${tag.isPrivate}');
}
