import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { sanitizeReplyArgs } from '../src/sanitize.js';

describe('sanitizeReplyArgs', () => {
  it('passes clean args through untouched', () => {
    const { args, fixed } = sanitizeReplyArgs({
      user_id: 'u_123',
      context_token: 'AAR_abc',
      content: 'hello',
    });
    assert.equal(fixed.length, 0);
    assert.deepEqual(args, { user_id: 'u_123', context_token: 'AAR_abc', content: 'hello' });
  });

  it('truncates XML pollution on context_token', () => {
    const { args, fixed } = sanitizeReplyArgs({
      user_id: 'u_123',
      context_token: 'AAR_abc</context_token><parameter name="content">hi</parameter></invoke>',
      content: '',
    });
    assert.equal(args.context_token, 'AAR_abc');
    assert.ok(fixed.includes('context_token'));
  });

  it('recovers content from XML-polluted context_token when content is empty', () => {
    const { args, fixed } = sanitizeReplyArgs({
      user_id: 'u_123',
      context_token: 'AAR_abc</context_token><parameter name="content">真正的回复</parameter></invoke>',
      content: '',
    });
    assert.equal(args.content, '真正的回复');
    assert.ok(fixed.includes('content(recovered)'));
  });

  it('strips trailing </parameter></invoke> from content', () => {
    const { args, fixed } = sanitizeReplyArgs({
      user_id: 'u_123',
      context_token: 'AAR_abc',
      content: 'hello</parameter></invoke>',
    });
    assert.equal(args.content, 'hello');
    assert.ok(fixed.includes('content'));
  });

  it('handles missing input', () => {
    const { args, fixed } = sanitizeReplyArgs(undefined);
    assert.deepEqual(args, {});
    assert.equal(fixed.length, 0);
  });
});
