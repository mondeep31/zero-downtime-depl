-- "Expand" step of expand/contract: a new NULLABLE column.
-- Code that does not know about it keeps working, so this is safe to apply
-- while the previous release is still serving traffic.
ALTER TABLE items ADD COLUMN description text;
