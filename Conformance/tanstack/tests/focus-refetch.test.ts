import { describe, expect, it } from 'vitest'
import { focusManager } from '@tanstack/query-core'
import { advance, client, immediate, observe, settle } from './helpers'

describe('focus-refetch', () => {
  it('[focus-001] focus refetches stale active queries', async () => {
    const qc = client()
    qc.mount()
    const fn = immediate(() => 'A')
    observe(qc, { queryKey: ['a'], queryFn: fn.fn })
    await settle()
    focusManager.setFocused(false)
    focusManager.setFocused(true)
    await settle()
    expect(fn.count).toBe(2)
    qc.unmount()
  })

  it('[focus-002] focus respects freshness and the option', async () => {
    const qc = client()
    qc.mount()
    const fresh = immediate(() => 'f')
    const off = immediate(() => 'o')
    const always = immediate(() => 'a')
    observe(qc, { queryKey: ['fresh'], queryFn: fresh.fn, staleTime: Infinity })
    observe(qc, { queryKey: ['off'], queryFn: off.fn, refetchOnWindowFocus: false })
    observe(qc, { queryKey: ['always'], queryFn: always.fn, staleTime: Infinity, refetchOnWindowFocus: 'always' })
    await settle()
    focusManager.setFocused(false)
    focusManager.setFocused(true)
    await settle()
    expect(fresh.count).toBe(1)
    expect(off.count).toBe(1)
    expect(always.count).toBe(2)
    qc.unmount()
  })

  it('[focus-003] refetchInterval pauses in background', async () => {
    const qc = client()
    const fg = immediate(() => 'x')
    observe(qc, { queryKey: ['a'], queryFn: fg.fn, refetchInterval: 1000 })
    await settle()
    focusManager.setFocused(false)
    await advance(3000)
    expect(fg.count).toBe(1)

    const bg = immediate(() => 'y')
    observe(qc, { queryKey: ['b'], queryFn: bg.fn, refetchInterval: 1000, refetchIntervalInBackground: true })
    await settle()
    await advance(3000)
    expect(bg.count).toBe(4)
  })

  it('[focus-004] inactive queries are not refetched on focus', async () => {
    const qc = client()
    qc.mount()
    const fn = immediate(() => 'A')
    await qc.fetchQuery({ queryKey: ['a'], queryFn: fn.fn })
    focusManager.setFocused(false)
    focusManager.setFocused(true)
    await settle()
    expect(fn.count).toBe(1)
    qc.unmount()
  })
})
