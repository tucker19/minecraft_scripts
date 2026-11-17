-- Optional quarry-only startup. If you already have startup logic, keep it
-- and add the shell.execute line after any setup that must happen first.
-- "auto" never creates a job, even if recovery fails.
shell.execute("/chunk_dig", "auto")
