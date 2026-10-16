import { describe, expect, it } from 'vitest'
import { CancelledError } from '@tanstack/query-core'
import { client, controlled, observe, settle } from './helpers'

describe('cancellation', () => {
  it('[cancel-001] cancel the initial fetch → revert to pending', async () => {
    const qc = client()
    const fn = controlled()
    const p = qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    const rejection = p.catch((e) => e)
    await settle()
    await qc.cancelQueries({ queryKey: ['a'] })
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('pending')
    expect(s.fetchStatus).toBe('idle')
    expect(s.data).toBeUndefined()
    expect(s.error).toBeNull()
    expect(await rejection).toBeInstanceOf(CancelledError)
    await fn.resolveLast('late')
    expect(qc.getQueryState(['a'])!.data).toBeUndefined()
  })

  it('[cancel-002] cancel a refetch → revert to previous data', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    const fn = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    await qc.cancelQueries()
    let s = qc.getQueryState(['a'])!
    expect(s.status).toBe('success')
    expect(s.data).toBe('A')
    expect(s.fetchStatus).toBe('idle')
    await fn.resolveLast('B')
    s = qc.getQueryState(['a'])!
    expect(s.data).toBe('A')
  })

  it('[cancel-003] cancel aborts the signal', async () => {
    const qc = client()
    const fn = controlled({ readSignal: true })
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    await qc.cancelQueries()
    expect(fn.last().signal!.aborted).toBe(true)
  })

  it('[cancel-004] last observer leaves; signal consumed → abort and revert', async () => {
    const qc = client()
    const fn = controlled({ readSignal: true })
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    await settle()
    o.unsubscribe()
    await settle()
    expect(fn.last().signal!.aborted).toBe(true)
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('pending')
    expect(s.fetchStatus).toBe('idle')
  })

  it('[cancel-005] last observer leaves; signal not consumed → fetch completes', async () => {
    const qc = client()
    const fn = controlled()
    const o = observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    await settle()
    o.unsubscribe()
    await fn.resolveLast('A')
    const s = qc.getQueryState(['a'])!
    expect(s.data).toBe('A')
    expect(s.status).toBe('success')
  })

  it('[cancel-006] cancel without revert results in an error state', async () => {
    const qc = client()
    const fn = controlled()
    void qc.prefetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    await qc.getQueryCache().find({ queryKey: ['a'] })!.cancel({ revert: false })
    await settle()
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('error')
    expect(s.fetchStatus).toBe('idle')
    expect(s.error).toBeInstanceOf(CancelledError)
  })

  it('[cancel-007] cancelling an idle query is a no-op', async () => {
    const qc = client()
    qc.setQueryData(['a'], 'A')
    await qc.cancelQueries()
    const s = qc.getQueryState(['a'])!
    expect(s.status).toBe('success')
    expect(s.data).toBe('A')
  })

  it('[cancel-008] fetchQuery after cancel starts fresh', async () => {
    const qc = client()
    const fn = controlled()
    qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn }).catch(() => {})
    await settle()
    await qc.cancelQueries()
    const p = qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    await settle()
    await fn.resolveLast('A')
    expect(await p).toBe('A')
    expect(fn.count).toBe(2)
  })
})
