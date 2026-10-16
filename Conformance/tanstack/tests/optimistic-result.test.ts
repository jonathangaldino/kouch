import { describe, expect, it } from 'vitest'
import { QueryObserver } from '@tanstack/query-core'
import { client, controlled, immediate, observe, settle } from './helpers'

// Framework adapters mark options as optimistic before calling getOptimisticResult.
const optimistic = (qc: any, options: any) => ({ ...qc.defaultQueryOptions(options), _optimisticResults: 'optimistic' })

describe('optimistic-result', () => {
  it('[opt-001] unmounted observer, empty cache', async () => {
    const qc = client()
    const fn = controlled()
    const options = { queryKey: ['a'], queryFn: fn.fn }
    const observer = new QueryObserver(qc, options)
    const r = observer.getOptimisticResult(optimistic(qc, options))
    expect(r.status).toBe('pending')
    expect(r.fetchStatus).toBe('fetching')
    expect(r.isLoading).toBe(true)
    await settle()
    expect(fn.count).toBe(0)
    expect(qc.getQueryState(['a'])!.fetchStatus).toBe('idle')
    expect(observer.getCurrentResult().fetchStatus).toBe('fetching')
  })

  it('[opt-002] fresh cached data', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const options = { queryKey: ['a'], queryFn: controlled().fn, staleTime: Infinity }
    const r = new QueryObserver(qc, options).getOptimisticResult(optimistic(qc, options))
    expect(r.status).toBe('success')
    expect(r.data).toBe('A')
    expect(r.fetchStatus).toBe('idle')
  })

  it('[opt-003] disabled', () => {
    const qc = client()
    const options = { queryKey: ['a'], queryFn: controlled().fn, enabled: false }
    const r = new QueryObserver(qc, options).getOptimisticResult(optimistic(qc, options))
    expect(r.status).toBe('pending')
    expect(r.fetchStatus).toBe('idle')
  })

  it('[opt-004] mounted observer, new key', async () => {
    const qc = client()
    const fn = immediate(() => 'one')
    const o = observe(qc, { queryKey: ['a', 1], queryFn: fn.fn })
    await settle()
    const fn2 = controlled()
    const r = o.observer.getOptimisticResult(optimistic(qc, { queryKey: ['a', 2], queryFn: fn2.fn }))
    expect(r.status).toBe('pending')
    expect(r.fetchStatus).toBe('fetching')
    expect(r.data).toBeUndefined()
    await settle()
    expect(fn2.count).toBe(0)
    expect(o.observer.getCurrentQuery().queryKey).toEqual(['a', 1])
  })
})
