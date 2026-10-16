import { afterEach, beforeEach, vi } from 'vitest'
import { environmentManager, focusManager, onlineManager } from '@tanstack/query-core'
import { T0 } from './helpers'

// Node looks like a server to TanStack (retry 0, gcTime Infinity). Model a client device.
environmentManager.setIsServer(() => false)

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(T0)
  onlineManager.setOnline(true)
  focusManager.setFocused(undefined)
})

afterEach(() => {
  vi.clearAllTimers()
  vi.useRealTimers()
})
