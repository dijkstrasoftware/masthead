defmodule Masthead.Repo.Migrations.BackfillGrowthTracking do
  use Ecto.Migration

  # Best-effort reconstruction for rows that predate growth tracking. See
  # docs/2026-10-10-growth-dashboard-spec.md, "Backfill".

  def up do
    execute """
    UPDATE sites s SET created_by_id = m.user_id
    FROM (
      SELECT DISTINCT ON (site_id) site_id, user_id
      FROM site_memberships
      ORDER BY site_id, inserted_at, id
    ) m
    WHERE m.site_id = s.id
    """

    execute "UPDATE users SET signup_method_inferred = true"

    execute """
    UPDATE users u SET signup_method = i.provider
    FROM (
      SELECT DISTINCT ON (user_id) user_id, provider, inserted_at
      FROM user_identities
      ORDER BY user_id, inserted_at, id
    ) i
    WHERE i.user_id = u.id
      AND i.provider IN ('google', 'github')
      AND abs(extract(epoch FROM i.inserted_at - u.inserted_at)) <= 60
    """

    execute """
    UPDATE users u SET signup_method = 'invite'
    FROM (
      SELECT DISTINCT ON (user_id) user_id, site_id, inserted_at
      FROM site_memberships
      ORDER BY user_id, inserted_at, id
    ) m
    JOIN sites s ON s.id = m.site_id
    WHERE m.user_id = u.id
      AND u.signup_method = 'email'
      AND m.inserted_at <= u.inserted_at + interval '10 minutes'
      AND s.inserted_at < u.inserted_at
      AND NOT EXISTS (SELECT 1 FROM sites c WHERE c.created_by_id = u.id)
    """

    execute "UPDATE pages SET published_at = inserted_at WHERE published"

    execute """
    WITH items AS (
      SELECT coalesce(p.author_id, s.created_by_id) AS user_id,
             p.site_id,
             p.inserted_at,
             greatest(p.published_at, p.inserted_at) AS at
      FROM posts p JOIN sites s ON s.id = p.site_id
      WHERE p.published_at IS NOT NULL
      UNION ALL
      SELECT s.created_by_id, pg.site_id, pg.inserted_at, pg.published_at
      FROM pages pg JOIN sites s ON s.id = pg.site_id
      WHERE pg.published_at IS NOT NULL
    ),
    firsts AS (
      SELECT DISTINCT ON (user_id) user_id, site_id, inserted_at, at
      FROM items
      WHERE user_id IS NOT NULL
      ORDER BY user_id, at
    )
    UPDATE users u SET
      activated_at = greatest(f.at, u.inserted_at),
      activated_via = CASE WHEN EXISTS (
        SELECT 1 FROM actions a
        WHERE a.site_id = f.site_id
          AND a.key = 'import_site'
          AND a.status = 'completed'
          AND abs(extract(epoch FROM a.updated_at - f.inserted_at)) <= 600
      ) THEN 'import' ELSE 'written' END
    FROM firsts f
    WHERE f.user_id = u.id
    """

    execute """
    UPDATE sites s SET initial_theme_id = ti.theme_id, theme_choice = 'chosen'
    FROM theme_installs ti
    WHERE ti.site_id = s.id
      AND abs(extract(epoch FROM ti.inserted_at - s.inserted_at)) <= 60
    """

    execute """
    UPDATE sites s SET
      initial_theme_id = s.theme_id,
      theme_choice = CASE WHEN t.slug = 'default' AND t.source = 'built_in'
                          THEN 'default' ELSE 'unknown' END
    FROM themes t
    WHERE t.id = s.theme_id AND s.theme_choice IS NULL
    """

    execute """
    INSERT INTO license_events (site_id, kind, source, plan, status, expires_at, occurred_at)
    SELECT id, 'backfill',
           CASE WHEN payment_subscription_id IS NOT NULL THEN 'stripe' ELSE 'gift' END,
           license_plan, license_status, license_expires_at, updated_at
    FROM sites
    WHERE license_status IN ('active', 'canceling') AND license_expires_at > now()
    """
  end

  def down do
    execute "DELETE FROM license_events WHERE kind = 'backfill'"
  end
end
