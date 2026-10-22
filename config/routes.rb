# frozen_string_literal: true

scope 'gk_records' do
  get  'notes', to: 'gk_records_notes#index'
  post 'notes', to: 'gk_records_notes#create', as: 'gk_records_notes'
  post 'notes/:id/void', to: 'gk_records_notes#void', as: 'gk_records_note_void'
  get  'events', to: 'gk_records_events#index', as: 'gk_records_events'
  get  'links/page', to: 'gk_records_links#page', as: 'gk_records_links_page'
  get  'links/tab', to: 'gk_records_links#tab', as: 'gk_records_links_tab'
  get  'links', to: 'gk_records_links#index'
  post 'links', to: 'gk_records_links#create', as: 'gk_records_links'
  post 'links/:id/void', to: 'gk_records_links#void', as: 'gk_records_link_void'
  get  'assessments/page', to: 'gk_records_assessments#page', as: 'gk_records_assessments_page'
  get  'assessments/tab', to: 'gk_records_assessments#tab', as: 'gk_records_assessments_tab'
  get  'assessments', to: 'gk_records_assessments#index', as: 'gk_records_assessments'
  get  'kinds', to: 'gk_records_kinds#index', as: 'gk_records_kinds'
  # Administration > Skäl
  get   'reasons', to: 'gk_records_reasons#index', as: 'gk_records_reasons'
  patch 'reasons/:key', to: 'gk_records_reasons#update', as: 'gk_records_reason', constraints: { key: %r{[^/]+} }, format: false
  # Administration > Inläsningar, and a reading's page
  get 'readings', to: 'gk_records_readings#index', as: 'gk_records_readings'
  get 'readings/:id', to: 'gk_records_readings#show', as: 'gk_records_reading', constraints: { id: /\d+/ }
  # A verification status set by hand (target: "key:id")
  post 'verification', to: 'gk_records_verifications#update', as: 'gk_records_verification'
  # The document list's template
  get 'document_import/template', to: 'gk_records_document_imports#template', as: 'gk_records_document_import_template'
  # A global id resolved to the thing here (GET /gk_records/identities/<gid>.json)
  get 'identities/:gid', to: 'gk_records_identities#show', as: 'gk_records_identity', constraints: { gid: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/ },
                         defaults: { format: 'json' }
end

# A project's events (the project module Händelser, 1.01.000)
get 'projects/:project_id/gk_records_events', to: 'gk_records_events#index', as: 'project_gk_records_events'

# Läs in dokument, per project (the Dokument tab links here)
get  'projects/:project_id/document_import', to: 'gk_records_document_imports#new', as: 'gk_records_document_import'
post 'projects/:project_id/document_import', to: 'gk_records_document_imports#create'
get  'projects/:project_id/document_import/preview', to: 'gk_records_document_imports#preview', as: 'gk_records_document_import_preview'
post 'projects/:project_id/document_import/run', to: 'gk_records_document_imports#run', as: 'gk_records_document_import_run'
post 'projects/:project_id/document_import/discard', to: 'gk_records_document_imports#discard', as: 'gk_records_document_import_discard'
