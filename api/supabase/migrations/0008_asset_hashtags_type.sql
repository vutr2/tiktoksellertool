-- Allow the "hashtags" asset type.
--
-- Industry-aware listings emit a hashtags asset alongside title/description.
-- The original CHECK only permitted image/title/description/script, so
-- complete_generation's asset insert violated the constraint and failed the
-- whole settlement — surfacing as a 503 after the model had already run.

alter table assets drop constraint if exists assets_type_check;
alter table assets add constraint assets_type_check
  check (type in ('image', 'title', 'description', 'script', 'hashtags'));
