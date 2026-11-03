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
  Textarea,
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
        <AccountDialog paymentMethodId={paymentMethodId} onClose={() => setAdding(false)} />
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
          {set.beneficiary_address ? (
            <dd className="whitespace-pre-line text-muted-foreground">{set.beneficiary_address}</dd>
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
  const [editing, setEditing] = useState(false)
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
              <>
                <Button variant="outline" size="sm" onClick={() => setEditing(true)}>
                  {t('admin.bank_payments.accounts.edit')}
                </Button>
                <Button variant="ghost" size="sm" disabled={destroy.isPending} onClick={remove}>
                  {t('admin.bank_payments.accounts.delete')}
                </Button>
              </>
            )}
          </div>
        ) : null}
      </CardContent>
      {editing ? (
        <AccountDialog
          paymentMethodId={paymentMethodId}
          account={account}
          onClose={() => setEditing(false)}
        />
      ) : null}
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

/** A detail set as the form edits it: schemes as one comma-separated line. */
interface DetailSetDraft {
  label: string
  beneficiary_name: string
  beneficiary_address: string
  schemes: string
  fields: FieldRow[]
}

const blankField = (): FieldRow => ({ label: '', value: '' })

const blankSet = (): DetailSetDraft => ({
  label: '',
  beneficiary_name: '',
  beneficiary_address: '',
  schemes: '',
  fields: [blankField()],
})

function toDraft(set: DetailSet): DetailSetDraft {
  return {
    label: set.label ?? '',
    beneficiary_name: set.beneficiary_name ?? '',
    beneficiary_address: set.beneficiary_address ?? '',
    schemes: (set.schemes ?? []).join(', '),
    fields: set.fields.length > 0 ? set.fields.map((field) => ({ ...field })) : [blankField()],
  }
}

/** Blank values are left out, and a field needs both a name and a value. */
function fromDraft(draft: DetailSetDraft): DetailSet {
  const label = draft.label.trim()
  const beneficiaryName = draft.beneficiary_name.trim()
  const beneficiaryAddress = draft.beneficiary_address.trim()
  const schemes = draft.schemes
    .split(',')
    .map((scheme) => scheme.trim())
    .filter(Boolean)

  return {
    ...(label ? { label } : {}),
    ...(beneficiaryName ? { beneficiary_name: beneficiaryName } : {}),
    ...(beneficiaryAddress ? { beneficiary_address: beneficiaryAddress } : {}),
    ...(schemes.length > 0 ? { schemes } : {}),
    fields: draft.fields
      .map((field) => ({ label: field.label.trim(), value: field.value.trim() }))
      .filter((field) => field.label && field.value),
  }
}

/**
 * Adds an account, or edits one added by hand, for stores whose reconciler
 * cannot sync accounts. An account can carry several sets of details (a
 * local scheme and SWIFT, say): customers are shown every one.
 */
function AccountDialog({
  paymentMethodId,
  account,
  onClose,
}: {
  paymentMethodId: string
  account?: BankAccount
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [currency, setCurrency] = useState(account?.currency ?? '')
  const [sets, setSets] = useState<DetailSetDraft[]>(
    account && account.detail_sets.length > 0 ? account.detail_sets.map(toDraft) : [blankSet()],
  )
  const save = useResourceMutation({
    mutationFn: () => {
      const body = { currency, details: sets.map(fromDraft) }
      return account
        ? bankPaymentsClient.accounts.update(paymentMethodId, account.id, body)
        : bankPaymentsClient.accounts.create(paymentMethodId, body)
    },
    invalidate: [[accountsKey, paymentMethodId]],
    successMessage: account
      ? t('admin.bank_payments.accounts.updated')
      : t('admin.bank_payments.accounts.created'),
    showValidationErrors: true,
    onSuccess: onClose,
  })

  const setSet = (index: number, change: Partial<DetailSetDraft>) =>
    setSets(sets.map((set, i) => (i === index ? { ...set, ...change } : set)))
  const setField = (setIndex: number, fieldIndex: number, change: Partial<FieldRow>) =>
    setSet(setIndex, {
      fields: sets[setIndex].fields.map((field, i) =>
        i === fieldIndex ? { ...field, ...change } : field,
      ),
    })

  return (
    <Dialog open onOpenChange={(open) => (open ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {account
              ? t('admin.bank_payments.accounts.edit_title')
              : t('admin.bank_payments.accounts.add_title')}
          </DialogTitle>
          <DialogDescription>{t('admin.bank_payments.accounts.add_description')}</DialogDescription>
        </DialogHeader>
        <DialogBody className="flex flex-col gap-4">
          <div className="flex flex-col gap-2">
            <Label htmlFor="bank-account-currency">
              {t('admin.bank_payments.fields.currency')}
            </Label>
            <Input
              id="bank-account-currency"
              value={currency}
              maxLength={3}
              onChange={(event) => setCurrency(event.target.value.toUpperCase())}
            />
          </div>
          {sets.map((set, setIndex) => (
            // biome-ignore lint/suspicious/noArrayIndexKey: detail sets have no identity until saved
            <fieldset key={setIndex} className="flex flex-col gap-2 rounded-md border p-3">
              <legend className="px-1 text-sm font-medium">
                {t('admin.bank_payments.accounts.set_title', { number: setIndex + 1 })}
              </legend>
              <Label htmlFor={`bank-account-${setIndex}-label`}>
                {t('admin.bank_payments.accounts.detail_label')}
              </Label>
              <Input
                id={`bank-account-${setIndex}-label`}
                value={set.label}
                placeholder={t('admin.bank_payments.accounts.detail_label_placeholder')}
                onChange={(event) => setSet(setIndex, { label: event.target.value })}
              />
              <Label htmlFor={`bank-account-${setIndex}-beneficiary`}>
                {t('admin.bank_payments.accounts.beneficiary_name')}
              </Label>
              <Input
                id={`bank-account-${setIndex}-beneficiary`}
                value={set.beneficiary_name}
                onChange={(event) => setSet(setIndex, { beneficiary_name: event.target.value })}
              />
              <Label htmlFor={`bank-account-${setIndex}-address`}>
                {t('admin.bank_payments.accounts.beneficiary_address')}
              </Label>
              <Textarea
                id={`bank-account-${setIndex}-address`}
                value={set.beneficiary_address}
                onChange={(event) => setSet(setIndex, { beneficiary_address: event.target.value })}
              />
              <Label htmlFor={`bank-account-${setIndex}-schemes`}>
                {t('admin.bank_payments.accounts.schemes')}
              </Label>
              <Input
                id={`bank-account-${setIndex}-schemes`}
                value={set.schemes}
                placeholder={t('admin.bank_payments.accounts.schemes_placeholder')}
                onChange={(event) => setSet(setIndex, { schemes: event.target.value })}
              />
              {set.fields.map((field, fieldIndex) => (
                // biome-ignore lint/suspicious/noArrayIndexKey: rows have no identity until saved
                <div key={fieldIndex} className="flex gap-2">
                  <Input
                    aria-label={t('admin.bank_payments.accounts.field_label')}
                    placeholder={t('admin.bank_payments.accounts.field_label')}
                    value={field.label}
                    onChange={(event) =>
                      setField(setIndex, fieldIndex, { label: event.target.value })
                    }
                  />
                  <Input
                    aria-label={t('admin.bank_payments.accounts.field_value')}
                    placeholder={t('admin.bank_payments.accounts.field_value')}
                    value={field.value}
                    onChange={(event) =>
                      setField(setIndex, fieldIndex, { value: event.target.value })
                    }
                  />
                  {set.fields.length > 1 ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() =>
                        setSet(setIndex, { fields: set.fields.filter((_, i) => i !== fieldIndex) })
                      }
                    >
                      {t('admin.bank_payments.accounts.remove_field')}
                    </Button>
                  ) : null}
                </div>
              ))}
              <div className="flex gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setSet(setIndex, { fields: [...set.fields, blankField()] })}
                >
                  {t('admin.bank_payments.accounts.add_field')}
                </Button>
                {sets.length > 1 ? (
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setSets(sets.filter((_, i) => i !== setIndex))}
                  >
                    {t('admin.bank_payments.accounts.remove_set')}
                  </Button>
                ) : null}
              </div>
            </fieldset>
          ))}
          <div>
            <Button variant="outline" size="sm" onClick={() => setSets([...sets, blankSet()])}>
              {t('admin.bank_payments.accounts.add_set')}
            </Button>
          </div>
        </DialogBody>
        <DialogFooter>
          <Button disabled={currency.length !== 3 || save.isPending} onClick={() => save.mutate()}>
            {t('admin.bank_payments.accounts.save')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
