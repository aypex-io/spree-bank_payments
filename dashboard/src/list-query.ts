import type { ListParams } from './client'

/** Sent as they are; every other key is a Ransack filter. */
const PASSTHROUGH = new Set(['page', 'limit', 'expand', 'sort', 'fields'])

/**
 * The dashboard's ResourceTable hands a list call flat Ransack predicates
 * (`state_in`, `reference_raw_or_payer_name_cont`, `occurred_at_gteq`), and
 * Spree's Admin API reads filters only from `q[...]`. The SDK's own resource
 * clients wrap them (its `transformListParams`, which it doesn't export);
 * `adminClient.request` sends params as given, so this does the same for the
 * gem's endpoints. Without it every queue filter and the search are ignored.
 */
export function listQuery(params: ListParams | undefined): ListParams | undefined {
  if (!params) return undefined

  const query: ListParams = {}
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) continue
    if (PASSTHROUGH.has(key) || key.startsWith('q[')) {
      query[key] = value
    } else if (Array.isArray(value)) {
      query[`q[${key.replace(/\[\]$/, '')}][]`] = value
    } else {
      query[`q[${key}]`] = value
    }
  }
  return query
}
