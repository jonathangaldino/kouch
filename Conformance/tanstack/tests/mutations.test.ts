import { describe, expect, it } from 'vitest'
import { MutationCache, MutationObserver, onlineManager } from '@tanstack/query-core'
import { advance, client, immediate, observe, settle, T0 } from './helpers'

function deferredFn<T = string>() {
  const calls: { vars: unknown; resolve: (v: T) => void; reject: (e: unknown) => void }[] = []
  const fn = (vars: unknown) => new Promise<T>((resolve, reject) => calls.push({ vars, resolve, reject }))
  return { fn, calls }
}

function mutationObserver(qc: any, options: any) {
  const observer = new MutationObserver(qc, options)
  const results: any[] = []
  const unsubscribe = observer.subscribe((r) => results.push(r))
  return { observer, results, unsubscribe, get current() { return observer.getCurrentResult() } }
}

describe('mutations', () => {
  it('[mut-001] observer starts idle', () => {
    const qc = client()
    const o = new MutationObserver(qc, { mutationFn: async () => 'x' })
    const r = o.getCurrentResult()
    expect(r.status).toBe('idle')
    expect(r.isIdle).toBe(true)
    expect(r.data).toBeUndefined()
    expect(r.variables).toBeUndefined()
  })

  it('[mut-002] successful mutate', async () => {
    const qc = client()
    const fn = deferredFn()
    const o = mutationObserver(qc, { mutationFn: fn.fn })
    const p = o.observer.mutate('vars')
    await settle()
    expect(o.current.status).toBe('pending')
    expect(o.current.variables).toBe('vars')
    expect(o.current.submittedAt).toBe(T0)
    fn.calls[0]!.resolve('done')
    await settle()
    expect(o.current.status).toBe('success')
    expect(o.current.data).toBe('done')
    expect(await p).toBe('done')
    expect(fn.calls[0]!.vars).toBe('vars')
  })

  it('[mut-003] callback order on success', async () => {
    const log: string[] = []
    let onSuccessArgs: unknown[] = []
    const mutationCache = new MutationCache({
      onMutate: () => { log.push('cache.onMutate') },
      onSuccess: () => { log.push('cache.onSuccess') },
      onSettled: () => { log.push('cache.onSettled') },
    })
    const qc = client({ mutationCache })
    const o = mutationObserver(qc, {
      mutationFn: async () => { log.push('mutationFn'); return 'd' },
      onMutate: () => { log.push('onMutate'); return 'ctx' },
      onSuccess: (...args: unknown[]) => { log.push('onSuccess'); onSuccessArgs = args.slice(0, 3) },
      onSettled: () => { log.push('onSettled') },
    })
    await o.observer.mutate('v', {
      onSuccess: () => { log.push('mutate.onSuccess') },
      onSettled: () => { log.push('mutate.onSettled') },
    })
    await settle()
    expect(log).toEqual([
      'cache.onMutate', 'onMutate', 'mutationFn', 'cache.onSuccess', 'onSuccess',
      'cache.onSettled', 'onSettled', 'mutate.onSuccess', 'mutate.onSettled',
    ])
    expect(onSuccessArgs).toEqual(['d', 'v', 'ctx'])
    expect(o.current.context).toBe('ctx')
  })

  it('[mut-004] error', async () => {
    const log: string[] = []
    const E = new Error('E')
    const mutationCache = new MutationCache({
      onError: () => { log.push('cache.onError') },
      onSettled: () => { log.push('cache.onSettled') },
    })
    const qc = client({ mutationCache })
    const o = mutationObserver(qc, {
      mutationFn: async () => { throw E },
      onError: () => { log.push('onError') },
      onSettled: () => { log.push('onSettled') },
    })
    const result = await o.observer.mutate('v', {
      onError: () => { log.push('mutate.onError') },
      onSettled: () => { log.push('mutate.onSettled') },
    }).catch((e) => e)
    await settle()
    expect(log).toEqual(['cache.onError', 'onError', 'cache.onSettled', 'onSettled', 'mutate.onError', 'mutate.onSettled'])
    expect(o.current.status).toBe('error')
    expect(o.current.error).toBe(E)
    expect(o.current.failureCount).toBe(1)
    expect(o.current.data).toBeUndefined()
    expect(result).toBe(E)
  })

  it('[mut-005] retries are off by default', async () => {
    const qc = client()
    let n = 0
    const fn = async () => { n++; throw new Error('E') }
    await new MutationObserver(qc, { mutationFn: fn }).mutate(undefined).catch(() => {})
    expect(n).toBe(1)
    n = 0
    const p = new MutationObserver(qc, { mutationFn: fn, retry: 2, retryDelay: 10 }).mutate(undefined).catch(() => {})
    await advance(100)
    await p
    expect(n).toBe(3)
  })

  it('[mut-006] offline mutations pause and resume', async () => {
    const qc = client()
    qc.mount()
    onlineManager.setOnline(false)
    let called = 0
    const o = mutationObserver(qc, { mutationFn: async () => { called++; return 'ok' } })
    void o.observer.mutate('v')
    await settle()
    expect(o.current.status).toBe('pending')
    expect(o.current.isPaused).toBe(true)
    expect(called).toBe(0)
    onlineManager.setOnline(true)
    await settle()
    expect(called).toBe(1)
    expect(o.current.status).toBe('success')
    expect(o.current.isPaused).toBe(false)
    qc.unmount()
  })

  it('[mut-007] same scope runs serially', async () => {
    const qc = client()
    const fn = deferredFn()
    const a = mutationObserver(qc, { mutationFn: fn.fn, scope: { id: 's' } })
    const b = mutationObserver(qc, { mutationFn: fn.fn, scope: { id: 's' } })
    void a.observer.mutate('1')
    void b.observer.mutate('2')
    await settle()
    expect(b.current.status).toBe('pending')
    expect(b.current.isPaused).toBe(true)
    expect(fn.calls.map((c) => c.vars)).toEqual(['1'])
    fn.calls[0]!.resolve('r1')
    await settle()
    expect(fn.calls.map((c) => c.vars)).toEqual(['1', '2'])

    const free = deferredFn()
    void new MutationObserver(qc, { mutationFn: free.fn }).mutate('x')
    void new MutationObserver(qc, { mutationFn: free.fn }).mutate('y')
    await settle()
    expect(free.calls).toHaveLength(2)
  })

  it('[mut-008] mutation garbage collection', async () => {
    const qc = client()
    const o = mutationObserver(qc, { mutationFn: async () => 'ok', gcTime: 1000 })
    await o.observer.mutate(undefined)
    o.unsubscribe()
    await advance(999)
    expect(qc.getMutationCache().getAll()).toHaveLength(1)
    await advance(1)
    expect(qc.getMutationCache().getAll()).toHaveLength(0)
  })

  it('[mut-009] reset', async () => {
    const qc = client()
    const o = mutationObserver(qc, { mutationFn: async () => 'ok' })
    await o.observer.mutate(undefined)
    expect(o.current.status).toBe('success')
    o.observer.reset()
    expect(o.current.status).toBe('idle')
    expect(o.current.data).toBeUndefined()
  })

  it('[mut-010] invalidate from onSuccess', async () => {
    const qc = client()
    const todos = immediate(() => 't')
    observe(qc, { queryKey: ['todos'], queryFn: todos.fn, staleTime: Infinity })
    await settle()
    const o = mutationObserver(qc, {
      mutationFn: async () => 'ok',
      onSuccess: () => qc.invalidateQueries({ queryKey: ['todos'] }),
    })
    await o.observer.mutate(undefined)
    await settle()
    expect(todos.count).toBe(2)
  })

  it('[mut-011] isMutating', async () => {
    const qc = client()
    const fn = deferredFn()
    void new MutationObserver(qc, { mutationFn: fn.fn }).mutate('a')
    void new MutationObserver(qc, { mutationFn: fn.fn }).mutate('b')
    await settle()
    expect(qc.isMutating()).toBe(2)
    fn.calls.forEach((c) => c.resolve('x'))
    await settle()
    expect(qc.isMutating()).toBe(0)
  })
})
