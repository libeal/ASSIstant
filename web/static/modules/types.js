/**
 * Shared frontend typedefs aligned with schema/domain.json and web protocol envelopes.
 *
 * @typedef {object} Job
 * @property {number} schema_version
 * @property {string} job_id
 * @property {string} request_id
 * @property {string} session_id
 * @property {"queued"|"running"|"succeeded"|"failed"|"cancelled"} status
 * @property {string} resource
 * @property {string} action
 * @property {number} version
 * @property {number} attempt
 * @property {number} max_attempts
 * @property {string} created_at ISO-8601 UTC timestamp.
 * @property {string} updated_at ISO-8601 UTC timestamp.
 * @property {Record<string, unknown>} payload
 * @property {Record<string, unknown>|null} [result]
 * @property {OutputBlock[]|null} [partial_output]
 *
 * @typedef {object} StepEntry
 * @property {number} index
 * @property {number} [number]
 * @property {string} [step_id]
 * @property {string} title
 * @property {string} [status]
 * @property {Record<string, any>} [step]
 * @property {Record<string, any>} [output]
 *
 * @typedef {object} Turn
 * @property {string} id
 * @property {number} number
 * @property {number} order
 * @property {string} title
 * @property {string} mode
 * @property {string} input
 * @property {string} status
 * @property {string} [created_at]
 * @property {string} [updated_at]
 * @property {string} [source]
 * @property {string} [jobId]
 * @property {Record<string, unknown>} result
 * @property {StepEntry[]} entries
 * @property {boolean} contextEligible
 *
 * @typedef {object} ApprovalCard
 * @property {string} [id]
 * @property {string} [type]
 * @property {string} [subject]
 * @property {string} [summary]
 * @property {Record<string, unknown>} [step]
 * @property {string} [risk_level]
 * @property {string[]} [reasons]
 * @property {string[]} [actions]
 *
 * @typedef {object} OutputBlock
 * @property {string} kind
 * @property {string} [title]
 * @property {string} [text]
 * @property {unknown} [json]
 * @property {number} [truncated_bytes]
 *
 * @typedef {object} ConfigSnapshot
 * @property {string} [provider]
 * @property {string} [provider_id]
 * @property {Record<string, unknown>} [agent_loop]
 * @property {{enabled?: boolean, allow_api_key_transmission?: boolean, release_version?: string}} [remote]
 * @property {{enabled?: boolean, host?: string, port?: number, metrics_enabled?: boolean}} [web]
 * @property {number} [context_turns]
 *
 * @typedef {object} AuditEvent
 * @property {number} [seq]
 * @property {string} [hash]
 * @property {string} [prev_hash]
 * @property {string} [stage]
 * @property {string} [type]
 * @property {string} [name]
 * @property {string} [status]
 * @property {string} [timestamp]
 * @property {Record<string, unknown>} [payload]
 * @property {string} [summary]
 */

export {};
