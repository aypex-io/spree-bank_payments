import { PageHeader, useResourceKey, useResourceMutation } from '@spree/dashboard-core'
import {
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
  Input,
  Label,
  Switch,
  useConfirm,
} from '@spree/dashboard-ui'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { bankPaymentsClient } from '../client'
import { useCanManageBankTransfers } from '../components/shared'
import type { BankAccount, DetailSet, ReportedAccount } from '../types'

const accountsKey = 'bank_payment_accounts'

/**
 * The accounts one bank transfer payment method takes money into. One can be
 * offered per currency; every active account is watched.
 */
export function AccountsPage({ paymentMethodId }: { paymentMethodId: string }) {
  const { t } = useTranslation()
  const canManage = useCanManageBankTransfers()
  const [syncing, setSyncing] = useState(false)
  const [adding, setAdding] = useState(false)
  const { data } = useQuery({
    queryKey: useResourceKey(accountsKey, paymentMethodId),
    queryFn: () => bankPaymentsClient.accounts.list(paymentMethodId),
  })
  const accounts = data?.data ?? []
  // The manual reconciler cannot list accounts, so a sync would always be
  // refused: offer it only for a provider reconciler, as 5.x did.
  const { data: health } = useQuery({
    queryKey: useResourceKey('bank_payment_health', paymentMethodId),
    queryFn: () => bankPaymentsClient.health(paymentMethodId),
  })
  const canSync = health !== undefined && health.reconciler !== 'manual'

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t('admin.bank_payments.accounts.title')}
        description={t('admin.bank_payments.accounts.description')}
        actions={
          canManage ? (
            <div className="flex gap-2">
              <Button variant="outline" size="sm" onClick={() => setAdding(true)}>
                {t('admin.bank_payments.accounts.add')}
              </Button>
              {canSync ? (
                <Button size="sm" onClick={() => setSyncing(true)}>
                  {t('admin.bank_payments.accounts.sync')}
                </Button>
              ) : null}
            </div>
          ) : null
        }
      />
      {accounts.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('admin.bank_payments.accounts.empty')}</p>
      ) : (
        accounts.map((account) => (
          <AccountCard key={account.id} account={account} paymentMethodId={paymentMethodId} />
        ))
      )}
      {syncing ? (
        <SyncDialog paymentMethodId={paymentMethodId} onClose={() => setSyncing(false)} />
      ) : null}
      {adding ? (
        <AddAccountDialog paymentMethodId={paymentMethodId} onClose={() => setAdding(false)} />
      ) : null}
    </div>
  )
}

function DetailSets({ sets }: { sets: DetailSet[] }) {
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      {sets.map((set, index) => (
        // biome-ignore lint/suspicious/noArrayIndexKey: detail sets have no id, and a label can repeat
        <dl key={`${set.label ?? 'set'}-${index}`} className="text-sm">
          {set.label ? <dt className="mb-1 font-medium">{set.label}</dt> : null}
          {set.beneficiary_name ? (
            <dd className="text-muted-foreground">{set.beneficiary_name}</dd>
          ) : null}
          {set.fields.map((field) => (
            <dd key={field.label}>
              <span className="text-muted-foreground">{field.label}:</span> {field.value}
            </dd>
          ))}
        </dl>
      ))}
    </div>
  )
}

function AccountCard({
  account,
  paymentMethodId,
}: {
  account: BankAccount
  paymentMethodId: string
}) {
  const { t } = useTranslation()
  const canManage = useCanManageBankTransfers()
  const confirm = useConfirm()
  const invalidate = [[accountsKey, paymentMethodId]]
  const update = useResourceMutation({
    mutationFn: (body: { offered?: boolean; active?: boolean }) =>
      bankPaymentsClient.accounts.update(paymentMethodId, account.id, body),
    invalidate,
    showValidationErrors: true,
  })
  const destroy = useResourceMutation({
    mutationFn: () => bankPaymentsClient.accounts.destroy(paymentMethodId, account.id),
    invalidate,
  })

  async function remove() {
    const confirmed = await confirm({
      title: t('admin.bank_payments.accounts.delete_title'),
      message: t('admin.bank_payments.accounts.delete_body'),
      confirmLabel: t('admin.bank_payments.accounts.delete'),
      variant: 'destructive',
    })
    if (confirmed) destroy.mutate()
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex flex-wrap items-center gap-2">
          {account.currency}
          {account.offered ? (
            <Badge variant="success">{t('admin.bank_payments.accounts.offered')}</Badge>
          ) : null}
          {account.active ? null : (
            <Badge variant="secondary">{t('admin.bank_payments.accounts.inactive')}</Badge>
          )}
          <Badge variant="outline">
            {account.synced
              ? t('admin.bank_payments.accounts.synced')
              : t('admin.bank_payments.accounts.manual')}
          </Badge>
          {account.pooled ? (
            <Badge variant="outline">{t('admin.bank_payments.pooled')}</Badge>
          ) : null}
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <DetailSets sets={account.detail_sets} />
        {canManage ? (
          <div className="flex flex-wrap items-center gap-4">
            <span className="flex items-center gap-2 text-sm">
              <Switch
                checked={account.offered}
                disabled={!account.active || update.isPending}
                onCheckedChange={(offered) => update.mutate({ offered })}
              />
              {t('admin.bank_payments.accounts.offer')}
            </span>
            <Button
              variant="outline"
              size="sm"
              disabled={update.isPending}
              onClick={() =>
                update.mutate({
                  active: !account.active,
                  ...(account.active ? { offered: false } : {}),
                })
              }
            >
              {account.active
                ? t('admin.bank_payments.accounts.deactivate')
                : t('admin.bank_payments.accounts.activate')}
            </Button>
            {account.synced ? null : (
              <Button variant="ghost" size="sm" disabled={destroy.isPending} onClick={remove}>
                {t('admin.bank_payments.accounts.delete')}
              </Button>
            )}
          </div>
        ) : null}
      </CardContent>
    </Card>
  )
}

function SyncDialog({
  paymentMethodId,
  onClose,
}: {
  paymentMethodId: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: plan, error } = useQuery({
    queryKey: useResourceKey(accountsKey, paymentMethodId, 'sync_plan'),
    queryFn: () => bankPaymentsClient.accounts.syncPlan(paymentMethodId),
    retry: false,
  })
  const sync = useResourceMutation({
    mutationFn: () => bankPaymentsClient.accounts.sync(paymentMethodId),
    invalidate: [[accountsKey, paymentMethodId]],
    successMessage: t('admin.bank_payments.accounts.synced_done'),
    onSuccess: onClose,
  })
  const nothing =
    plan &&
    [plan.create, plan.update, plan.deactivate, plan.skipped].every((list) => list.length === 0)
  const section = (title: string, accounts: (ReportedAccount | BankAccount)[]) =>
    accounts.length === 0 ? null : (
      <div className="flex flex-col gap-1 text-sm">
        <p className="font-medium">{title}</p>
        {accounts.map((account) => (
          <p key={account.provider_account_id ?? account.currency}>
            {account.currency} · {account.provider_account_id}
          </p>
        ))}
      </div>
    )

  return (
    <Dialog open onOpenChange={(open) => (open ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('admin.bank_payments.accounts.sync_title')}</DialogTitle>
          {error ? <DialogDescription>{(error as Error).message}</DialogDescription> : null}
        </DialogHeader>
        {plan ? (
          <DialogBody className="flex flex-col gap-4">
            {nothing ? (
              <p className="text-sm">{t('admin.bank_payments.accounts.sync_nothing')}</p>
            ) : null}
            {section(t('admin.bank_payments.accounts.sync_create'), plan.create)}
            {section(t('admin.bank_payments.accounts.sync_update'), plan.update)}
            {section(t('admin.bank_payments.accounts.sync_deactivate'), plan.deactivate)}
            {section(t('admin.bank_payments.accounts.sync_skipped'), plan.skipped)}
          </DialogBody>
        ) : null}
        {plan && !nothing ? (
          <DialogFooter>
            <Button disabled={sync.isPending} onClick={() => sync.mutate()}>
              {t('admin.bank_payments.accounts.sync_apply')}
            </Button>
          </DialogFooter>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}

interface FieldRow {
  label: string
  value: string
}

/** One account with one set of details, for stores whose reconciler cannot sync accounts. */
function AddAccountDialog({
  paymentMethodId,
  onClose,
}: {
  paymentMethodId: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [currency, setCurrency] = useState('')
  const [label, setLabel] = useState('')
  const [beneficiary, setBeneficiary] = useState('')
  const [rows, setRows] = useState<FieldRow[]>([{ label: '', value: '' }])
  const create = useResourceMutation({
    mutationFn: () =>
      bankPaymentsClient.accounts.create(paymentMethodId, {
        currency,
        details: [
          {
            ...(label ? { label } : {}),
            ...(beneficiary ? { beneficiary_name: beneficiary } : {}),
            fields: rows.filter((row) => row.label && row.value),
          },
        ],
      }),
    invalidate: [[accountsKey, paymentMethodId]],
    successMessage: t('admin.bank_payments.accounts.created'),
    showValidationErrors: true,
    onSuccess: onClose,
  })
  const setRow = (index: number, change: Partial<FieldRow>) =>
    setRows(rows.map((row, i) => (i === index ? { ...row, ...change } : row)))

  return (
    <Dialog open onOpenChange={(open) => (open ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('admin.bank_payments.accounts.add_title')}</DialogTitle>
          <DialogDescription>{t('admin.bank_payments.accounts.add_description')}</DialogDescription>
        </DialogHeader>
        <DialogBody className="flex flex-col gap-3">
          <Label htmlFor="bank-account-currency">{t('admin.bank_payments.fields.currency')}</Label>
          <Input
            id="bank-account-currency"
            value={currency}
            maxLength={3}
            onChange={(event) => setCurrency(event.target.value.toUpperCase())}
          />
          <Label htmlFor="bank-account-label">
            {t('admin.bank_payments.accounts.detail_label')}
          </Label>
          <Input
            id="bank-account-label"
            value={label}
            placeholder={t('admin.bank_payments.accounts.detail_label_placeholder')}
            onChange={(event) => setLabel(event.target.value)}
          />
          <Label htmlFor="bank-account-beneficiary">
            {t('admin.bank_payments.accounts.beneficiary_name')}
          </Label>
          <Input
            id="bank-account-beneficiary"
            value={beneficiary}
            onChange={(event) => setBeneficiary(event.target.value)}
          />
          {rows.map((row, index) => (
            // biome-ignore lint/suspicious/noArrayIndexKey: rows have no identity until saved
            <div key={index} className="flex gap-2">
              <Input
                aria-label={t('admin.bank_payments.accounts.field_label')}
                placeholder={t('admin.bank_payments.accounts.field_label')}
                value={row.label}
                onChange={(event) => setRow(index, { label: event.target.value })}
              />
              <Input
                aria-label={t('admin.bank_payments.accounts.field_value')}
                placeholder={t('admin.bank_payments.accounts.field_value')}
                value={row.value}
                onChange={(event) => setRow(index, { value: event.target.value })}
              />
              {rows.length > 1 ? (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setRows(rows.filter((_, i) => i !== index))}
                >
                  {t('admin.bank_payments.accounts.remove_field')}
                </Button>
              ) : null}
            </div>
          ))}
          <div>
            <Button
              variant="outline"
              size="sm"
              onClick={() => setRows([...rows, { label: '', value: '' }])}
            >
              {t('admin.bank_payments.accounts.add_field')}
            </Button>
          </div>
        </DialogBody>
        <DialogFooter>
          <Button
            disabled={currency.length !== 3 || create.isPending}
            onClick={() => create.mutate()}
          >
            {t('admin.bank_payments.accounts.save')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
