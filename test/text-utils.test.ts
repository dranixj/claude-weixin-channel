import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { stripMarkdown, chunkText } from '../src/text-utils.js';

describe('stripMarkdown', () => {
  it('removes bold and italic markers', () => {
    assert.equal(stripMarkdown('**hello** and *world*'), 'hello and world');
  });

  it('preserves code fence contents', () => {
    assert.equal(stripMarkdown('```js\nconst x = 1;\n```'), 'const x = 1;');
  });

  it('keeps link text, drops the URL', () => {
    assert.equal(stripMarkdown('see [docs](https://example.com) now'), 'see docs now');
  });

  it('removes heading markers', () => {
    assert.equal(stripMarkdown('# Title\n## Sub'), 'Title\nSub');
  });
});

describe('chunkText', () => {
  it('returns single chunk for short text', () => {
    assert.deepEqual(chunkText('hello', 100), ['hello']);
  });

  it('splits long text into multiple chunks', () => {
    const text = 'a'.repeat(100);
    const chunks = chunkText(text, 30);
    assert.ok(chunks.length > 1);
    assert.equal(chunks.join(''), text);
  });

  it('prefers double-newline break points', () => {
    const text = 'para1 aaaaa\n\npara2 bbbbb\n\npara3 ccccc';
    const chunks = chunkText(text, 20);
    assert.ok(chunks.length >= 2);
    assert.ok(chunks[0].startsWith('para1'));
  });
});
