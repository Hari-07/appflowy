import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:appflowy_editor/src/extensions/path_extensions.dart';
import 'package:appflowy_editor/src/render/rich_text/rich_text_style.dart';
import './number_list_helper.dart';

/// Handle some cases where enter is pressed and shift is not pressed.
///
/// 1. Multiple selection and the selected nodes are [TextNode]
///   1.1 delete the nodes expect for the first and the last,
///     and delete the text in the first and the last node by case.
/// 2. Single selection and the selected node is [TextNode]
///   2.1 split the node into two nodes with style
///   2.2 or insert a empty text node before.
ShortcutEventHandler enterWithoutShiftInTextNodesHandler =
    (editorState, event) {
  if (event.logicalKey != LogicalKeyboardKey.enter || event.isShiftPressed) {
    return KeyEventResult.ignored;
  }

  var selection = editorState.service.selectionService.currentSelection.value;
  var nodes = editorState.service.selectionService.currentSelectedNodes;
  if (selection == null) {
    return KeyEventResult.ignored;
  }
  if (selection.isForward) {
    selection = selection.reversed;
    nodes = nodes.reversed.toList(growable: false);
  }
  final textNodes = nodes.whereType<TextNode>().toList(growable: false);

  if (nodes.length != textNodes.length) {
    return KeyEventResult.ignored;
  }

  // Multiple selection
  if (!selection.isSingle) {
    final startNode = editorState.document.nodeAtPath(selection.start.path)!;
    final length = textNodes.length;
    final List<TextNode> subTextNodes =
        length >= 3 ? textNodes.sublist(1, textNodes.length - 1) : [];
    final afterSelection = Selection.collapsed(
      Position(path: textNodes.first.path.next, offset: 0),
    );
    TransactionBuilder(editorState)
      ..deleteText(
        textNodes.first,
        selection.start.offset,
        textNodes.first.toRawString().length,
      )
      ..deleteNodes(subTextNodes)
      ..deleteText(
        textNodes.last,
        0,
        selection.end.offset,
      )
      ..afterSelection = afterSelection
      ..commit();

    if (startNode is TextNode && startNode.subtype == StyleKey.numberList) {
      makeFollowingNodesIncremental(
          editorState, selection.start.path, afterSelection);
    }

    return KeyEventResult.handled;
  }

  // Single selection and the selected node is [TextNode]
  if (textNodes.length != 1) {
    return KeyEventResult.ignored;
  }

  final textNode = textNodes.first;

  // If selection is collapsed and position.start.offset == 0,
  //  insert a empty text node before.
  if (selection.isCollapsed && selection.start.offset == 0) {
    if (textNode.toRawString().isEmpty && textNode.subtype != null) {
      final afterSelection = Selection.collapsed(
        Position(path: textNode.path, offset: 0),
      );
      TransactionBuilder(editorState)
        ..updateNode(
            textNode,
            Attributes.fromIterable(
              StyleKey.globalStyleKeys,
              value: (_) => null,
            ))
        ..afterSelection = afterSelection
        ..commit();

      final nextNode = textNode.next;
      if (nextNode is TextNode && nextNode.subtype == StyleKey.numberList) {
        makeFollowingNodesIncremental(
            editorState, textNode.path, afterSelection,
            beginNum: 0);
      }
    } else {
      final subtype = textNode.subtype;
      final afterSelection = Selection.collapsed(
        Position(path: textNode.path.next, offset: 0),
      );

      if (subtype == StyleKey.numberList) {
        final prevNumber = textNode.attributes[StyleKey.number] as int;
        final newNode = TextNode.empty();
        newNode.attributes[StyleKey.subtype] = StyleKey.numberList;
        newNode.attributes[StyleKey.number] = prevNumber;
        final insertPath = textNode.path;
        TransactionBuilder(editorState)
          ..insertNode(
            insertPath,
            newNode,
          )
          ..afterSelection = afterSelection
          ..commit();

        makeFollowingNodesIncremental(editorState, insertPath, afterSelection,
            beginNum: prevNumber);
      } else {
        TransactionBuilder(editorState)
          ..insertNode(
            textNode.path,
            TextNode.empty(),
          )
          ..afterSelection = afterSelection
          ..commit();
      }
    }
    return KeyEventResult.handled;
  }

  // Otherwise,
  //  split the node into two nodes with style
  Attributes attributes = _attributesFromPreviousLine(textNode);

  final nextPath = textNode.path.next;
  final afterSelection = Selection.collapsed(
    Position(path: nextPath, offset: 0),
  );

  TransactionBuilder(editorState)
    ..insertNode(
      textNode.path.next,
      textNode.copyWith(
        attributes: attributes,
        delta: textNode.delta.slice(selection.end.offset),
      ),
    )
    ..deleteText(
      textNode,
      selection.start.offset,
      textNode.toRawString().length - selection.start.offset,
    )
    ..afterSelection = afterSelection
    ..commit();

  // If the new type of a text node is number list,
  // the numbers of the following nodes should be incremental.
  if (textNode.subtype == StyleKey.numberList) {
    makeFollowingNodesIncremental(editorState, nextPath, afterSelection);
  }

  return KeyEventResult.handled;
};

Attributes _attributesFromPreviousLine(TextNode textNode) {
  final prevAttributes = textNode.attributes;
  final subType = textNode.subtype;
  if (subType == null || subType == StyleKey.heading) {
    return {};
  }

  final copy = Attributes.from(prevAttributes);
  if (subType == StyleKey.numberList) {
    return _nextNumberAttributesFromPreviousLine(copy, textNode);
  }

  if (subType == StyleKey.checkbox) {
    copy[StyleKey.checkbox] = false;
    return copy;
  }

  return copy;
}

Attributes _nextNumberAttributesFromPreviousLine(
    Attributes copy, TextNode textNode) {
  final prevNum = textNode.attributes[StyleKey.number] as int?;
  copy[StyleKey.number] = prevNum == null ? 1 : prevNum + 1;
  return copy;
}
