/**
 * Registers the plugin's English strings with the dashboard's i18next.
 * Imported first by every module that looks a string up while it loads (the
 * queue table's labels), so the strings exist before the first lookup.
 */
import { i18n } from '@spree/dashboard-core'
import en from './locales/en.json'

i18n.addResourceBundle('en', 'translation', en, true, true)
