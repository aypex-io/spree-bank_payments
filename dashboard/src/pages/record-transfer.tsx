import { mapSpreeErrorsToForm, PageHeader } from '@spree/dashboard-core'
import {
  Button,
  Card,
  CardContent,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toastManager,
} from '@spree/dashboard-ui'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useEffect } from 'react'
import { Controller, useForm } from 'react-hook-form'
import { useTranslation } from 'react-i18next'
import { bankPaymentsClient } from '../client'
import { useStoreId } from '../components/shared'
import type { RecordTransferParams } from '../types'
import { transfersQueryKey } from './transfers-list'

/**
 * Records a transfer seen on the bank statement. An exact match is applied at
 * once and anything else waits in the queue; submitting the same transfer
 * twice records nothing twice.
 */
export function RecordTransferPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const storeId = useStoreId()
  // The gem's own list, not Spree's payment methods endpoint: that one needs
  // the store's settings, which a role that records transfers may not have.
  const { data: methods } = useQuery({
    queryKey: ['bank_payments', 'payment_methods', storeId],
    queryFn: () => bankPaymentsClient.paymentMethods(),
  })
  const bankMethods = methods?.data ?? []
  const form = useForm<RecordTransferParams>({
    defaultValues: {
      payment_method_id: '',
      amount: '',
      currency: '',
      reference: '',
      payer_name: '',
      occurred_at: new Date().toISOString().slice(0, 10),
    },
  })

  // Most stores have one bank transfer method: pick it, so the form is
  // never submitted with none.
  const firstMethodId = bankMethods[0]?.id
  useEffect(() => {
    if (firstMethodId && form.getValues('payment_method_id') === '') {
      form.setValue('payment_method_id', firstMethodId)
    }
  }, [firstMethodId, form])

  const onSubmit = form.handleSubmit(async (values) => {
    try {
      const transfer = await bankPaymentsClient.transfers.record(values)
      const title = transfer.already_recorded
        ? t('admin.bank_payments.record.already_recorded')
        : transfer.state === 'applied'
          ? t('admin.bank_payments.record.applied', { number: transfer.order?.number })
          : t('admin.bank_payments.record.queued')
      toastManager.add({ type: 'success', title })
      await queryClient.invalidateQueries({ queryKey: [transfersQueryKey] })
      navigate({ to: '/$storeId/bank-transfers', params: { storeId } })
    } catch (error) {
      if (!mapSpreeErrorsToForm(error, form.setError)) {
        toastManager.add({
          type: 'error',
          title: error instanceof Error ? error.message : String(error),
        })
      }
    }
  })

  const field = (name: keyof RecordTransferParams, label: string, type = 'text') => (
    <div className="flex flex-col gap-2">
      <Label htmlFor={`bank-transfer-${name}`}>{label}</Label>
      <Input id={`bank-transfer-${name}`} type={type} {...form.register(name)} />
      {form.formState.errors[name] ? (
        <p className="text-sm text-destructive">{form.formState.errors[name]?.message}</p>
      ) : null}
    </div>
  )

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t('admin.bank_payments.record.title')}
        description={t('admin.bank_payments.record.description')}
        backTo="/$storeId/bank-transfers"
      />
      <Card>
        <CardContent>
          <form className="grid max-w-xl gap-4" onSubmit={onSubmit}>
            <div className="flex flex-col gap-2">
              <Label>{t('admin.bank_payments.fields.payment_method')}</Label>
              <Controller
                control={form.control}
                name="payment_method_id"
                render={({ field: control }) => (
                  <Select
                    value={control.value}
                    onValueChange={(value) => control.onChange(value ?? '')}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {bankMethods.map((method) => (
                        <SelectItem key={method.id} value={method.id}>
                          {method.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              />
              {form.formState.errors.payment_method_id ? (
                <p className="text-sm text-destructive">
                  {form.formState.errors.payment_method_id.message}
                </p>
              ) : null}
            </div>
            {field('amount', t('admin.bank_payments.fields.amount'))}
            {field('currency', t('admin.bank_payments.fields.currency'))}
            {field('reference', t('admin.bank_payments.fields.reference'))}
            {field('payer_name', t('admin.bank_payments.fields.payer_name'))}
            {field('occurred_at', t('admin.bank_payments.fields.occurred_at'), 'date')}
            <div>
              <Button type="submit" disabled={form.formState.isSubmitting}>
                {t('admin.bank_payments.record.submit')}
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
