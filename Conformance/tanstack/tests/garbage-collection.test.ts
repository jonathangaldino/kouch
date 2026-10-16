import { describe, expect, it } from 'vitest'
import { advance, client, controlled, immediate, observe, settle } from './helpers'

const exists = (qc: any, key: unknown[]) => qc.getQueryCache().find({ queryKey: key }) !== undefined

describe('garbage-collection', () => {
  it('[gc-001] unobserved query removed after default gcTime', async () => {
    const qc = client()
    await qc.fetchQuery({ queryKey: ['a'], queryFn: immediate(() => 'A').fn })
    await advance(299_999)
    expect(exists(qc, ['a'])).toBe(true)
    await advance(1)
    expect(exists(qc, ['a'])).toBe(false)
  })

  it('[gc-002] last observer unsubscribes → removed after gcTime', async () => {
    const qc = client()
    const o = observe(qc, { queryKey: ['a'], queryFn: immediate(() => 'A').fn, gcTime: 1000 })
    await settle()
    o.unsubscribe()
    await advance(999)
    expect(exists(qc, ['a'])).toBe(true)
    expect(qc.getQueryData(['a'])).toBe('A')
    await advance(1)
    expect(exists(qc, ['a'])).toBe(false)
  })

  it('[gc-003] new observer before GC rescues the query', async () => {
    const qc = client()
    const fn = immediate(() => 'A')
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn, gcTime: 1000 })
    await settle()
    o.unsubscribe()
    await advance(500)
    const o2 = observe(qc, { queryKey: ['a'], queryFn: fn.fn, gcTime: 1000, staleTime: Infinity })
    expect(o2.current.status).toBe('success')
    expect(o2.current.data).toBe('A')
    await settle()
    expect(fn.count).toBe(1)
    await advance(4500)
    expect(exists(qc, ['a'])).toBe(true)
  })

  it('[gc-004] gcTime Infinity never collects', async () => {
    const qc = client()
    await qc.fetchQuery({ queryKey: ['a'], queryFn: immediate(() => 'A').fn, gcTime: Infinity })
    await advance(365 * 24 * 3600 * 1000)
    expect(exists(qc, ['a'])).toBe(true)
  })

  it('[gc-005] largest gcTime wins', async () => {
    const qc = client()
    await qc.fetchQuery({ queryKey: ['a'], queryFn: immediate(() => 'A').fn, gcTime: 10_000 })
    await qc.fetchQuery({ queryKey: ['a'], queryFn: immediate(() => 'A').fn, gcTime: 1000 })
    await advance(1000)
    expect(exists(qc, ['a'])).toBe(true)
    await advance(9000)
    expect(exists(qc, ['a'])).toBe(false)
  })

  it('[gc-006] fetching queries are not collected', async () => {
    const qc = client()
    const fn = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn, gcTime: 1000 })
    await settle()
    await advance(1000)
    expect(exists(qc, ['a'])).toBe(true)
    await advance(4000)
    await fn.resolveLast('A')
    await advance(999)
    expect(exists(qc, ['a'])).toBe(true)
    await advance(1)
    expect(exists(qc, ['a'])).toBe(false)
  })

  it('[gc-007] gcTime 0', async () => {
    const qc = client()
    const o = observe(qc, { queryKey: ['a'], queryFn: immediate(() => 'A').fn, gcTime: 0 })
    await settle()
    o.unsubscribe()
    await advance(0)
    expect(exists(qc, ['a'])).toBe(false)
  })

  it('[gc-008] remaining observer keeps the query', async () => {
    const qc = client()
    const fn = immediate(() => 'A')
    const o1 = observe(qc, { queryKey: ['a'], queryFn: fn.fn, gcTime: 1000 })
    observe(qc, { queryKey: ['a'], queryFn: fn.fn, gcTime: 1000 })
    await settle()
    o1.unsubscribe()
    await advance(5000)
    expect(exists(qc, ['a'])).toBe(true)
    expect(qc.getQueryCache().find({ queryKey: ['a'] })!.getObserversCount()).toBe(1)
  })
})
