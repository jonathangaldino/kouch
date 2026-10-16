import { describe, expect, it } from 'vitest'
import { client } from './helpers'

const keys = (qs: { queryKey: readonly unknown[] }[]) => qs.map((q) => JSON.stringify(q.queryKey)).sort()

describe('query-key', () => {
  it('[key-001] object key order does not affect identity', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    const a = cache.build(qc, { queryKey: ['todos', { status: 'done', page: 1 }] })
    const b = cache.build(qc, { queryKey: ['todos', { page: 1, status: 'done' }] })
    expect(a).toBe(b)
    expect(cache.getAll()).toHaveLength(1)
  })

  it('[key-002] different keys are different queries', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    expect(cache.build(qc, { queryKey: ['user', 1] })).not.toBe(cache.build(qc, { queryKey: ['user', 2] }))
    expect(cache.getAll()).toHaveLength(2)
  })

  it('[key-003] array element order matters', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    expect(cache.build(qc, { queryKey: ['a', 1, 2] })).not.toBe(cache.build(qc, { queryKey: ['a', 2, 1] }))
  })

  it('[key-004] prefix filter matches by leading elements', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    for (const k of [['todos'], ['todos', 1], ['todos', { done: true }], ['todo'], ['posts']]) cache.build(qc, { queryKey: k })
    expect(keys(cache.findAll({ queryKey: ['todos'] }))).toEqual(keys([{ queryKey: ['todos'] }, { queryKey: ['todos', 1] }, { queryKey: ['todos', { done: true }] }]))
  })

  it('[key-005] object filter element matches by subset', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    cache.build(qc, { queryKey: ['todos', { status: 'done', page: 1 }] })
    cache.build(qc, { queryKey: ['todos', { status: 'open', page: 1 }] })
    const found = cache.findAll({ queryKey: ['todos', { status: 'done' }] })
    expect(found).toHaveLength(1)
    expect(found[0]!.queryKey).toEqual(['todos', { status: 'done', page: 1 }])
  })

  it('[key-006] exact filter matches only the identical key', () => {
    const qc = client()
    const cache = qc.getQueryCache()
    cache.build(qc, { queryKey: ['todos'] })
    cache.build(qc, { queryKey: ['todos', 1] })
    const found = cache.findAll({ queryKey: ['todos'], exact: true })
    expect(found.map((q) => q.queryKey)).toEqual([['todos']])
  })
})
