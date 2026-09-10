/**
 * In-memory deduplication store capped at `max` entries.
 * Uses insertion-order eviction (oldest dropped first) to bound memory.
 */
export class EventDedupe {
  private readonly _ids = new Set<string>()
  private readonly _queue: string[] = []
  private readonly _max: number

  constructor(max = 200) {
    this._max = max
  }

  has(id: string): boolean {
    return this._ids.has(id)
  }

  add(id: string): void {
    if (this._ids.has(id)) return
    if (this._queue.length >= this._max) {
      const oldest = this._queue.shift()!
      this._ids.delete(oldest)
    }
    this._ids.add(id)
    this._queue.push(id)
  }
}
