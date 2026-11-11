import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
const source = html.match(/<script id="handoff-model">([\s\S]*?)<\/script>/)[1];
const model = vm.runInNewContext(`${source}; Handoff`);
const notes = { id: 'notes', value: '', start: 0, end: 0, known: true, editable: true };
const chat = { ...notes, id: 'chat' };
const begin = (mode = 'safe', origin = notes) => model.begin(1, 'Private thought.', origin, mode);

test('staying in the same field inserts without a confirmation step', () => {
  const result = model.finish(begin(), 1, notes);
  assert.equal(result.status, 'inserted');
  assert.equal(model.insert(result.destination, result.text), 'Private thought.');
});
test('a different destination holds the result without an insertion target', () => {
  const result = model.finish(begin(), 1, chat);
  assert.equal(result.status, 'held');
  assert.equal(result.destination, null);
});
test('returning after an interruption still requires explicit consent', () => {
  const interrupted = model.observe(begin(), chat);
  const held = model.finish(interrupted, 1, notes);
  assert.equal(held.status, 'held');
  assert.equal(model.observe(held, notes), held);
  assert.equal(model.confirm(held, notes).status, 'inserted');
});
test('confirmation refuses a different destination', () => {
  const held = model.finish(begin(), 1, chat);
  assert.equal(model.confirm(held, chat), held);
});
test('same app is insufficient: field identity must match', () => {
  assert.equal(model.finish(begin(), 1, { ...notes, id: 'notes-title' }).status, 'held');
});
test('editing the original field or moving its caret blocks automatic insertion', () => {
  for (const change of [{ value: 'New content' }, { start: 1, end: 1 }, { end: 1 }]) {
    assert.equal(model.finish(begin(), 1, { ...notes, ...change }).status, 'held');
  }
});
test('unverifiable and non-editable destinations fail closed in both modes', () => {
  for (const mode of ['safe', 'baseline']) for (const target of [null, { ...notes, known: false }, { ...notes, editable: false }]) {
    assert.equal(model.finish(begin(mode), 1, target).status, 'held');
    const held = model.finish(begin(), 1, chat);
    assert.equal(model.confirm(held, target), held);
  }
});
test('losing visibility stays held even after visibility returns', () => {
  const hidden = model.observe(begin(), { ...notes, known: false });
  assert.equal(model.finish(hidden, 1, notes).status, 'held');
});
test('the comparison mode follows the selected field', () => {
  const result = model.finish(begin('baseline'), 1, chat);
  assert.equal(result.status, 'inserted');
  assert.equal(result.destination.id, 'chat');
});
test('explicit insertion uses the currently confirmed selection, not the stale one', () => {
  const held = model.finish(begin(), 1, chat);
  const current = { ...notes, value: 'Before old after', start: 7, end: 10 };
  const result = model.confirm(held, current);
  assert.equal(model.insert(result.destination, result.text), 'Before Private thought. after');
});
test('duplicate, stale and cancelled completions never insert', () => {
  const fresh = model.begin(2, 'Second sample', notes);
  assert.equal(model.finish(fresh, 1, chat), fresh);
  const delivered = model.finish(begin(), 1, notes);
  assert.equal(model.finish(delivered, 1, notes), delivered);
  assert.equal(model.confirm(delivered, notes), delivered);
  const cancelled = model.discard(begin(), 'cancelled');
  assert.equal(model.finish(cancelled, 1, notes), cancelled);
  assert.equal(cancelled.text, '');
  assert.equal(model.finish(null, 1, notes), null);
});
test('discard clears the held transcript and disables late insertion', () => {
  const discarded = model.discard(model.finish(begin(), 1, chat));
  assert.equal(discarded.text, '');
  assert.equal(discarded.destination, null);
  assert.equal(model.confirm(discarded, notes), discarded);
});
test('user input remains plain text, including Unicode and HTML-looking strings', () => {
  const text = '私のメモ 🙂 <img src=x onerror=alert(1)>';
  assert.equal(model.insert(notes, text), text);
  assert.equal(html.includes('innerHTML'), false);
});
test('the artifact is self-contained, network-blocked, and does not persist data', () => {
  assert.match(html, /connect-src 'none'/);
  assert.doesNotMatch(html, /<script[^>]+src=|<link[^>]+href=|localStorage|sessionStorage|indexedDB|fetch\(/);
});
