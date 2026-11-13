-- Cover the six remaining unindexed marketplace foreign-key columns.
-- Existing feed/filter, owner/time and primary-key indexes remain unchanged.
-- Ordinary index builds block writes: apply only in a reviewed maintenance window.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- location_id is not the leading column of the existing listings_filter index.
create index listings_location_id_idx on public.listings using btree (location_id);
create index listings_owner_id_idx on public.listings using btree (owner_id);
create index media_listing_id_idx on public.media using btree (listing_id);
create index media_owner_id_idx on public.media using btree (owner_id);
create index reports_reporter_id_idx on public.reports using btree (reporter_id);
-- upload_owner_time already covers owner_id, but not listing-only FK lookups.
create index upload_intents_listing_id_idx on public.upload_intents using btree (listing_id);

-- Deliberately omit IF NOT EXISTS: an unexpected same-name object must fail,
-- not silently substitute an incorrect index. The transaction rolls back all six.
commit;
