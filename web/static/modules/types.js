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
 * @property {string} [title]
 * @property {string} [input]
 * @property {string} [command]
 * @property {Record<string, any>} [response]
 * @property {Record<string, any>} [context]
 * @property {Record<string, any>} [review]
 * @property {Record<string, any>} [executionState]
 * @property {ApprovalCard} [card]
 * @property {number} [index]
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
 * @property {{enabled?: boolean}} [command_guard]
 * @property {boolean} [api_key_configured]
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
 * @property {Record<string, any>} [data]
 *
 * @typedef {Record<string, any>} ApiResponse
 *
 * @typedef {object} RequestOptions
 * @property {string} [method]
 * @property {Record<string, any>} [body]
 * @property {Record<string, string>} [headers]
 * @property {AbortSignal} [signal]
 *
 * @typedef {object} AppState
 * @property {string} token
 * @property {Array<Record<string, any>>} tools
 * @property {Record<string, any>|null} workPlan
 * @property {Record<string, any>|null} workContext
 * @property {string} workPlanInput
 * @property {boolean} awaitingWorkApproval
 * @property {Record<string, any>|null} editPackage
 * @property {Array<Record<string, any>>} policyFiles
 * @property {string} currentPolicyPath
 * @property {string} policySudoPassword
 * @property {boolean} policySudoUnlocked
 * @property {Record<string, any>|null} auditBoundaries
 * @property {Array<Record<string, any>>|null} skillTree
 * @property {{markdown: string[], scripts: string[]}} skillFiles
 * @property {Array<Record<string, any>>} mcpServers
 * @property {Array<Record<string, any>>} mcpTools
 * @property {Array<Record<string, any>>} mcpFindings
 * @property {string} mcpRoot
 * @property {string} activeWorkJobId
 * @property {string} activeScriptJobId
 * @property {string} activeTerminalJobId
 * @property {boolean} workSubmitting
 * @property {boolean} workApprovalSubmitting
 * @property {boolean} terminalSubmitting
 * @property {number} selectedStepIndex
 * @property {string} selectedTurnId
 * @property {string} selectedStepKey
 * @property {boolean} approvalDrawerOpen
 * @property {ApprovalCard|null} pendingApproval
 * @property {Record<string, any>|null} lastProtocolResult
 * @property {Turn[]} sessionTurns
 * @property {Record<string, any>|null} sessionInfo
 * @property {string} restoredAuditSessionId
 * @property {string} lastThinkingSummary
 * @property {boolean} workSuspended
 * @property {Array<Record<string, any>>} auditSessions
 * @property {AuditEvent[]} auditEvents
 * @property {Record<string, any>|null} auditWebTimeline
 * @property {string} auditTimelineUnavailableReason
 * @property {string} currentAuditSession
 * @property {ConfigSnapshot|null} configSnapshot
 * @property {boolean} commandGuardEnabled
 * @property {Record<string, any>} configOriginal
 * @property {Record<string, any>} configDraft
 * @property {Array<Record<string, any>>} configProviders
 * @property {Array<Record<string, any>>} configModels
 * @property {string} configModelsProvider
 * @property {string} configModelStatus
 * @property {Record<string, any>|null} domainSchema
 * @property {Record<string, any>|null} observerBootstrap
 * @property {boolean} observerBootstrapPrompted
 * @property {boolean} auditPaused
 * @property {string} draggedPanelId
 * @property {string} webRunId
 * @property {string} layoutStorageKey
 * @property {{containers: Record<string, string[]>, children: Record<string, string[]>}} defaultLayout
 *
 * @typedef {(path: string, options?: RequestOptions) => Promise<ApiResponse>} ApiRequest
 * @typedef {(...args: any[]) => any} ViewAction
 *
 * @typedef {object} AppContext
 * @property {AppState} state
 * @property {ApiRequest} api
 * @property {ApiRequest} request
 * @property {(id: string) => any} $
 * @property {(id: string, eventName: string, handler: (event: any) => void) => void} on
 * @property {(id: string, value: unknown) => void} setText
 * @property {(id: string, value: string, kind?: string) => void} setStatus
 * @property {(id: string, enabled: boolean) => void} setSwitch
 * @property {(message: string) => void} showToast
 * @property {(value: unknown) => string} pretty
 * @property {(value: unknown) => string} escapeHtml
 * @property {(text: string) => HTMLElement} emptyItem
 * @property {(text: string) => HTMLElement} emptyEvent
 * @property {(risk: string) => string} riskKind
 * @property {(kind: string) => string} pillKind
 * @property {Record<string, string>} titles
 * @property {typeof import("./audit.js")} auditProtocol
 * @property {Array<Record<string, any>>} CONFIG_GROUPS
 * @property {Array<Record<string, any>>} CONFIG_READONLY_FIELDS
 * @property {string} THINKING_TRACE_KEY
 * @property {string} REMOTE_API_KEY_TRANSMISSION_KEY
 * @property {Set<string>} hiddenOutputKeys
 * @property {Record<string, string>} outputLabelMap
 * @property {number} auditListReloadTimer
 * @property {number} sessionTurnCounter
 * @property {number} sessionTurnCounterRef
 * @property {ViewAction} statusKind
 * @property {ViewAction} printOutput
 * @property {ViewAction} renderMarkdown
 * @property {ViewAction} createJob
 * @property {ViewAction} cancelJob
 * @property {ViewAction} pollJob
 * @property {ViewAction} outputBlocksFrom
 * @property {ViewAction} outputBlocksText
 * @property {ViewAction} outputBlocksSummary
 * @property {ViewAction} renderOutputBlocksHtml
 * @property {ViewAction} userOutputBlocks
 * @property {ViewAction} findBlockJson
 * @property {ViewAction} normalizeExecutionEntries
 * @property {ViewAction} completedExecutionCount
 * @property {ViewAction} normalizeApprovalCard
 * @property {ViewAction} primaryOutputObject
 * @property {ViewAction} outputSummaryText
 * @property {ViewAction} renderOutputSection
 * @property {ViewAction} renderPrimaryOutputHtml
 * @property {ViewAction} terminalReturnPayload
 * @property {ViewAction} renderTerminalReturnHtml
 * @property {ViewAction} renderMetaRows
 * @property {ViewAction} renderJsonDetails
 * @property {ViewAction} isPlainObject
 * @property {ViewAction} isEmptyOutputValue
 * @property {ViewAction} extractRawOutput
 * @property {ViewAction} renderUserOutputText
 * @property {ViewAction} renderArrayOutputText
 * @property {ViewAction} renderObjectOutputText
 * @property {ViewAction} renderProtocolText
 * @property {ViewAction} renderSharedExecutionOutput
 * @property {ViewAction} executionFlowBlocks
 * @property {ViewAction} renderExecutionFlowHtml
 * @property {ViewAction} entryStepKey
 * @property {ViewAction} normalizedTurnEntries
 * @property {ViewAction} workPlanMarkdown
 * @property {ViewAction} turnCanEnterContextPure
 * @property {ViewAction} createSessionTurnPure
 * @property {ViewAction} normalizeRestoredTurnPure
 * @property {ViewAction} upsertSessionTurnPure
 * @property {ViewAction} contextTurnCapacityPure
 * @property {ViewAction} contextMetaByTurnPure
 * @property {ViewAction} safeAction
 * @property {ViewAction} showScreen
 * @property {ViewAction} parseJsonText
 * @property {ViewAction} firstLine
 *
 * @typedef {object} AuditViewContract
 * @property {ViewAction} loadAuditList
 * @property {ViewAction} scheduleAuditListReload
 * @property {ViewAction} renderAuditSessionList
 * @property {ViewAction} renderAuditEventTimeline
 * @property {ViewAction} exportAuditReport
 * @property {ViewAction} downloadRuntimeBackup
 * @property {ViewAction} toggleAuditPause
 * @property {ViewAction} findAuditFailure
 * @property {ViewAction} restoreAuditTimelineToWorkbench
 *
 * @typedef {object} ConfigViewContract
 * @property {ViewAction} loadConfig
 * @property {ViewAction} saveConfigChanges
 * @property {ViewAction} updateConfigDraftFromControl
 * @property {ViewAction} fetchConfigModels
 * @property {ViewAction} toggleThinkingTraceFromConfig
 * @property {ViewAction} toggleThinkingTraceFromWorkbench
 *
 * @typedef {object} PolicyViewContract
 * @property {ViewAction} runDoctor
 * @property {ViewAction} updatePolicyEditState
 * @property {ViewAction} loadPolicies
 * @property {ViewAction} unlockPolicy
 * @property {ViewAction} validatePolicy
 * @property {ViewAction} savePolicy
 * @property {ViewAction} openPolicyFile
 * @property {ViewAction} closePolicyFileDialog
 * @property {ViewAction} toggleCommandGuard
 * @property {ViewAction} lockPolicy
 * @property {ViewAction} readPolicy
 *
 * @typedef {object} SkillsViewContract
 * @property {ViewAction} loadSense
 * @property {ViewAction} loadTools
 * @property {ViewAction} loadSkillTree
 * @property {ViewAction} validateSkills
 * @property {ViewAction} loadMcpRegistry
 * @property {ViewAction} loadMcpTools
 * @property {ViewAction} validateMcp
 * @property {ViewAction} reviewScript
 * @property {ViewAction} runScript
 * @property {ViewAction} cancelScript
 * @property {ViewAction} startNewSkill
 * @property {ViewAction} planEdit
 * @property {ViewAction} reviewEdit
 * @property {ViewAction} applyEdit
 * @property {ViewAction} markEditDirty
 *
 * @typedef {object} WorkbenchViewContract
 * @property {ViewAction} updateWorkActionLabel
 * @property {ViewAction} updateTerminalActionState
 * @property {ViewAction} loadSessionState
 * @property {ViewAction} runWork
 * @property {ViewAction} cancelWork
 * @property {ViewAction} suspendWork
 * @property {ViewAction} leaveWorkbenchSession
 * @property {ViewAction} closeApprovalDrawer
 * @property {ViewAction} submitApprovalDecision
 * @property {ViewAction} runTerminal
 * @property {ViewAction} renderThinkingSummary
 * @property {ViewAction} renderSessionTimeline
 * @property {ViewAction} setThinkingSwitches
 * @property {ViewAction} thinkingTraceEnabled
 * @property {ViewAction} updateRemoteActionState
 * @property {ViewAction} restoreTimelineFromAudit
 *
 * @typedef {object} ObserverBootstrapViewContract
 * @property {ViewAction} loadObserverBootstrapStatus
 * @property {ViewAction} openObserverAuditDialog
 * @property {ViewAction} enableObserverAudit
 * @property {ViewAction} skipObserverAudit
 *
 * @typedef {AuditViewContract & Record<string, ViewAction>} AuditView
 * @typedef {ConfigViewContract & Record<string, ViewAction>} ConfigView
 * @typedef {PolicyViewContract & Record<string, ViewAction>} PolicyView
 * @typedef {SkillsViewContract & Record<string, ViewAction>} SkillsView
 * @typedef {WorkbenchViewContract & Record<string, ViewAction>} WorkbenchView
 * @typedef {ObserverBootstrapViewContract & Record<string, ViewAction>} ObserverBootstrapView
 * @typedef {AppContext & AuditViewContract & ConfigViewContract & PolicyViewContract & SkillsViewContract & WorkbenchViewContract & ObserverBootstrapViewContract} ApplicationController
 */

export {};
