-- The app's own table.
CREATE TABLE todos (
    id INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0
);
