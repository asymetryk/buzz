import { TextSelection, type Transaction } from "@tiptap/pm/state";
import { canSplit } from "@tiptap/pm/transform";

function canSplitInsideTextblock(
  transaction: Transaction,
  position: number,
): boolean {
  const $position = transaction.doc.resolve(position);
  return (
    $position.parent.inlineContent &&
    $position.parentOffset > 0 &&
    $position.parentOffset < $position.parent.content.size &&
    canSplit(transaction.doc, position)
  );
}

function mapRangeThroughLatestStep(
  transaction: Transaction,
  from: number,
  to: number,
): { from: number; to: number } {
  const stepMap = transaction.steps.at(-1)?.getMap();
  return stepMap
    ? {
        from: stepMap.map(from, 1),
        to: stepMap.map(to, -1),
      }
    : { from, to };
}

/**
 * Isolate the hard-break-delimited line under a collapsed caret.
 *
 * The composer represents Shift+Enter lines as `hardBreak` nodes inside one
 * paragraph, so a block toggle at a collapsed caret otherwise reformats every
 * line of the draft. Replacing the line's bordering hard breaks with block
 * splits gives the caret's line its own textblock, which scopes the following
 * block toggle to just that line.
 */
function isolateCaretLineForBlockFormatting(transaction: Transaction): boolean {
  const { $from } = transaction.selection;
  if (!$from.parent.isTextblock || !$from.parent.inlineContent) return false;

  const blockStart = $from.start();
  const blockEnd = $from.end();
  let caret = transaction.selection.from;

  let lineFrom = blockStart;
  let lineTo = blockEnd;
  $from.parent.forEach((child, offset) => {
    if (child.type.name !== "hardBreak") return;
    const breakFrom = blockStart + offset;
    const breakTo = breakFrom + child.nodeSize;
    if (breakTo <= caret) lineFrom = breakTo;
    if (breakFrom >= caret) lineTo = Math.min(lineTo, breakFrom);
  });

  // No hard breaks around the caret — the line already is the whole
  // textblock, so the block toggle is correctly scoped as-is.
  if (lineFrom === blockStart && lineTo === blockEnd) return false;

  const nodeAfterLine = transaction.doc.resolve(lineTo).nodeAfter;
  if (nodeAfterLine?.type.name === "hardBreak") {
    transaction.delete(lineTo, lineTo + nodeAfterLine.nodeSize);
    if (canSplit(transaction.doc, lineTo)) {
      transaction.split(lineTo);
      const stepMap = transaction.steps.at(-1)?.getMap();
      if (stepMap) {
        caret = stepMap.map(caret, -1);
        lineFrom = stepMap.map(lineFrom, -1);
      }
    }
  }

  const nodeBeforeLine = transaction.doc.resolve(lineFrom).nodeBefore;
  if (nodeBeforeLine?.type.name === "hardBreak") {
    transaction.delete(lineFrom - nodeBeforeLine.nodeSize, lineFrom);
    let stepMap = transaction.steps.at(-1)?.getMap();
    if (stepMap) {
      caret = stepMap.map(caret, 1);
      lineFrom = stepMap.map(lineFrom, -1);
    }
    if (canSplit(transaction.doc, lineFrom)) {
      transaction.split(lineFrom);
      stepMap = transaction.steps.at(-1)?.getMap();
      if (stepMap) caret = stepMap.map(caret, 1);
    }
  }

  transaction.setSelection(TextSelection.create(transaction.doc, caret));
  return true;
}

/**
 * Isolate the current text selection at exact block boundaries.
 *
 * ProseMirror's block commands operate on whole textblocks. The composer can
 * hold an entire draft in one paragraph, so toggling a list or code block for
 * a substring otherwise formats the whole draft. Splitting at the selection
 * end and start first gives the selected text its own block while preserving
 * the surrounding content as sibling paragraphs. A collapsed caret isolates
 * its hard-break-delimited line so the block format starts at that line.
 *
 * This mutates the transaction supplied by a Tiptap command chain so the
 * isolation and the following block toggle remain one undoable edit.
 */
export function isolateSelectionForBlockFormatting(
  transaction: Transaction,
): boolean {
  if (!(transaction.selection instanceof TextSelection)) {
    return false;
  }

  if (transaction.selection.empty) {
    return isolateCaretLineForBlockFormatting(transaction);
  }

  const isBackward = transaction.selection.anchor > transaction.selection.head;
  let { from, to } = transaction.selection;

  const nodeAfterSelection = transaction.doc.resolve(to).nodeAfter;
  if (nodeAfterSelection?.type.name === "hardBreak") {
    transaction.delete(to, to + nodeAfterSelection.nodeSize);
    ({ from, to } = mapRangeThroughLatestStep(transaction, from, to));
  }

  const nodeBeforeSelection = transaction.doc.resolve(from).nodeBefore;
  if (nodeBeforeSelection?.type.name === "hardBreak") {
    transaction.delete(from - nodeBeforeSelection.nodeSize, from);
    ({ from, to } = mapRangeThroughLatestStep(transaction, from, to));
  }

  if (canSplitInsideTextblock(transaction, to)) {
    transaction.split(to);
    ({ from, to } = mapRangeThroughLatestStep(transaction, from, to));
  }

  if (canSplitInsideTextblock(transaction, from)) {
    transaction.split(from);
    ({ from, to } = mapRangeThroughLatestStep(transaction, from, to));
  }

  transaction.setSelection(
    TextSelection.create(
      transaction.doc,
      isBackward ? to : from,
      isBackward ? from : to,
    ),
  );
  return true;
}
