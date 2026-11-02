import { SpreeError } from '@spree/admin-sdk'
import { PageHeader, useResourceKey, useResourceMutation } from '@spree/dashboard-core'
import {
  Alert,
  AlertDescription,
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Label,
  RelativeTime,
  Textarea,
  toastManager,
  useConfirm,
} from '@spree/dashboard-ui'
import { useQuery } from '@tanstack/react-query'
import { Link, useNavigate } from '@tanstack/react-router'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { bankPaymentsClient } from '../client'
import {
  money,
  TransferStateBadge,
  useCanManageBankTransfers,
  useStoreId,
} from '../components/shared'
import type { AmountMismatchDetails, IncomingTransfer, Suggestion } from '../types'
import { transfersQueryKey } from './transfers-list'

/**
 * One transfer and the open sessions it could belong to. Applying a transfer
 * for a different amount takes a second, confirmed click; ignoring needs a
 * reason.
 */
export function TransferDetailPage({ transferId }: { transferId: string }) {
  const { t } = useTranslation()
  const transferKey = useResourceKey(transfersQueryKey, transferId)
  const { data: transfer } = useQuery({
    queryKey: transferKey,
    queryFn: () => bankPaymentsClient.transfers.get(transferId),
  })

  if (!transfer) return null

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t('admin.bank_payments.transfer.title', {
          reference: transfer.reference || t('admin.bank_payments.transfer.no_reference'),
        })}
        backTo="/$storeId/bank-transfers"
        badges={<TransferStateBadge state={transfer.state} />}
      />
      <TransferFacts transfer={transfer} />
      {transfer.state === 'unmatched' ? (
        <Suggestions transfer={transfer} />
      ) : (
        <Outcome transfer={transfer} />
      )}
    </div>
  )
}

function TransferFacts({ transfer }: { transfer: IncomingTransfer }) {
  const { t } = useTranslation()
  const rows: [string, React.ReactNode][] = [
    [t('admin.bank_payments.fields.amount'), money(transfer.amount, transfer.currency)],
    [t('admin.bank_payments.fields.reference'), transfer.reference || '—'],
    [t('admin.bank_payments.fields.payer_name'), transfer.payer_name || '—'],
    [
      t('admin.bank_payments.fields.occurred_at'),
      <RelativeTime key="at" iso={transfer.occurred_at} />,
    ],
    [
      t('admin.bank_payments.fields.account'),
      transfer.bank_account ? (
        <span key="account" className="flex items-center gap-2">
          {transfer.bank_account.currency} {transfer.bank_account.provider_account_id}
          {transfer.bank_account.pooled ? (
            <Badge variant="outline">{t('admin.bank_payments.pooled')}</Badge>
          ) : null}
        </span>
      ) : (
        '—'
      ),
    ],
  ]

  return (
    <Card>
      <CardContent>
        <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
          {rows.map(([label, value]) => (
            <div key={label} className="contents">
              <dt className="text-muted-foreground">{label}</dt>
              <dd>{value}</dd>
            </div>
          ))}
        </dl>
        {transfer.bank_account?.pooled ? (
          <Alert className="mt-4">
            <AlertDescription>{t('admin.bank_payments.transfer.pooled_warning')}</AlertDescription>
          </Alert>
        ) : null}
      </CardContent>
    </Card>
  )
}

function Outcome({ transfer }: { transfer: IncomingTransfer }) {
  const { t } = useTranslation()
  const storeId = useStoreId()

  return (
    <Card>
      <CardContent className="text-sm">
        {transfer.order ? (
          <Link to="/$storeId/orders/$orderId" params={{ storeId, orderId: transfer.order.id }}>
            {t('admin.bank_payments.transfer.applied_to', { number: transfer.order.number })}
          </Link>
        ) : (
          <p>
            {t('admin.bank_payments.fields.ignored_reason')}: {transfer.ignored_reason}
          </p>
        )}
      </CardContent>
    </Card>
  )
}

function Suggestions({ transfer }: { transfer: IncomingTransfer }) {
  const { t } = useTranslation()
  const canManage = useCanManageBankTransfers()
  const confirm = useConfirm()
  const navigate = useNavigate()
  const storeId = useStoreId()
  const [ignoring, setIgnoring] = useState(false)
  const { data } = useQuery({
    queryKey: useResourceKey(transfersQueryKey, transfer.id, 'suggestions'),
    queryFn: () => bankPaymentsClient.transfers.suggestions(transfer.id),
  })
  const backToQueue = () => navigate({ to: '/$storeId/bank-transfers', params: { storeId } })

  const apply = useResourceMutation({
    mutationFn: (variables: { suggestion: Suggestion; confirm_mismatch?: boolean }) =>
      bankPaymentsClient.transfers.apply(transfer.id, {
        payment_session_id: variables.suggestion.id,
        confirm_mismatch: variables.confirm_mismatch,
      }),
    invalidate: [[transfersQueryKey]],
    successMessage: false,
    // A mismatch is answered with a confirmation, not a toast; every other
    // refusal toasts here.
    errorMessage: false,
    onSuccess: (_transfer, variables) => {
      toastManager.add({
        type: 'success',
        title: t('admin.bank_payments.transfer.applied', {
          number: variables.suggestion.order.number,
        }),
      })
      backToQueue()
    },
  })

  async function applyTo(suggestion: Suggestion) {
    try {
      await apply.mutateAsync({ suggestion })
    } catch (error) {
      if (!(error instanceof SpreeError) || error.code !== 'amount_mismatch') {
        toastManager.add({
          type: 'error',
          title: error instanceof Error ? error.message : String(error),
        })
        return
      }

      const details = error.details as unknown as AmountMismatchDetails
      const confirmed = await confirm({
        title: t('admin.bank_payments.transfer.mismatch_title'),
        message: t('admin.bank_payments.transfer.mismatch_body', {
          ...details,
          number: suggestion.order.number,
        }),
        confirmLabel: t('admin.bank_payments.transfer.mismatch_confirm'),
      })
      if (!confirmed) return

      await apply
        .mutateAsync({ suggestion, confirm_mismatch: true })
        .catch((retryError: unknown) => {
          toastManager.add({
            type: 'error',
            title: retryError instanceof Error ? retryError.message : String(retryError),
          })
        })
    }
  }

  const suggestions = data?.data ?? []

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('admin.bank_payments.transfer.suggestions')}</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {suggestions.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('admin.bank_payments.transfer.no_suggestions')}
          </p>
        ) : (
          suggestions.map((suggestion) => (
            <div
              key={suggestion.id}
              className="flex items-center justify-between gap-4 rounded-md border p-3"
            >
              <div className="flex flex-col gap-1 text-sm">
                <span className="font-medium">
                  {suggestion.order.number} · {money(suggestion.amount, suggestion.currency)}
                  {suggestion.exact_match ? (
                    <Badge variant="success" className="ml-2">
                      {t('admin.bank_payments.transfer.exact_match')}
                    </Badge>
                  ) : null}
                </span>
                <span className="text-muted-foreground">
                  {suggestion.reference}
                  {suggestion.order.customer_name ? ` · ${suggestion.order.customer_name}` : ''}
                  {suggestion.order.email ? ` · ${suggestion.order.email}` : ''}
                </span>
              </div>
              {canManage ? (
                <Button size="sm" disabled={apply.isPending} onClick={() => applyTo(suggestion)}>
                  {t('admin.bank_payments.transfer.apply', { number: suggestion.order.number })}
                </Button>
              ) : null}
            </div>
          ))
        )}
        {canManage ? (
          <div>
            <Button variant="outline" size="sm" onClick={() => setIgnoring(true)}>
              {t('admin.bank_payments.transfer.ignore')}
            </Button>
          </div>
        ) : null}
      </CardContent>
      <IgnoreDialog
        transfer={transfer}
        open={ignoring}
        onOpenChange={setIgnoring}
        onIgnored={backToQueue}
      />
    </Card>
  )
}

function IgnoreDialog({
  transfer,
  open,
  onOpenChange,
  onIgnored,
}: {
  transfer: IncomingTransfer
  open: boolean
  onOpenChange: (open: boolean) => void
  onIgnored: () => void
}) {
  const { t } = useTranslation()
  const [reason, setReason] = useState('')
  const ignore = useResourceMutation({
    mutationFn: () => bankPaymentsClient.transfers.ignore(transfer.id, reason),
    invalidate: [[transfersQueryKey]],
    successMessage: t('admin.bank_payments.transfer.ignored'),
    showValidationErrors: true,
    onSuccess: onIgnored,
  })

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('admin.bank_payments.transfer.ignore_title')}</DialogTitle>
          <DialogDescription>{money(transfer.amount, transfer.currency)}</DialogDescription>
        </DialogHeader>
        <DialogBody className="flex flex-col gap-2">
          <Label htmlFor="bank-transfer-ignore-reason">
            {t('admin.bank_payments.transfer.ignore_reason_label')}
          </Label>
          <Textarea
            id="bank-transfer-ignore-reason"
            value={reason}
            placeholder={t('admin.bank_payments.transfer.ignore_reason_placeholder')}
            onChange={(event) => setReason(event.target.value)}
          />
        </DialogBody>
        <DialogFooter>
          <Button
            disabled={reason.trim() === '' || ignore.isPending}
            onClick={() => ignore.mutate()}
          >
            {t('admin.bank_payments.transfer.ignore')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
