CREATE OR REPLACE FUNCTION wipe_reporting(
       source_param varchar(6)
) RETURNS void AS $$
BEGIN
    DELETE FROM task_history_recat
     WHERE source = source_param;

    DELETE FROM tall_backlog
     WHERE source = source_param;

    DELETE FROM category_list
     WHERE source = source_param;

    DELETE FROM recently_closed
     WHERE source = source_param;

    DELETE FROM recently_closed_task
     WHERE source = source_param;

    DELETE FROM maintenance_week
     WHERE source = source_param;

    DELETE FROM maintenance_delta
     WHERE source = source_param;

    DELETE FROM velocity
     WHERE source = source_param;

    DELETE FROM open_backlog_size
     WHERE source = source_param;

END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION find_recently_closed(
    source_prefix varchar(6)
    ) RETURNS void AS $$
DECLARE
  weekrow record;
BEGIN

    DELETE FROM recently_closed
     WHERE source = source_prefix;

    FOR weekrow IN SELECT DISTINCT date
                     FROM task_history_recat
                    WHERE EXTRACT(epoch FROM age(date - INTERVAL '1 day'))/604800 = ROUND(
                          EXTRACT(epoch FROM age(date - INTERVAL '1 day'))/604800)
                      AND source = source_prefix
                    ORDER BY date
    LOOP

        INSERT INTO recently_closed (
            SELECT source_prefix as source,
                   date,
                   category,
                   sum(points) AS points,
                   count(title) as count
              FROM task_history_recat
             WHERE status = '"resolved"'
               AND date = weekrow.date
               AND source = source_prefix
               AND id NOT IN (SELECT id
                                FROM task_history
                               WHERE status = '"resolved"'
                                 AND source = source_prefix
                                 AND date = weekrow.date - interval '1 week' )
             GROUP BY date, category
             );
    END LOOP;

    RETURN;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION find_recently_closed_task(
    source_prefix varchar(6)
    ) RETURNS void AS $$
DECLARE
  daterow record;
BEGIN

    DELETE FROM recently_closed_task
     WHERE source = source_prefix;

    FOR daterow IN SELECT DISTINCT date
                     FROM task_history_recat
                    WHERE source = source_prefix
                      AND date > now() - interval '14 days'
                    ORDER BY date
    LOOP

        INSERT INTO recently_closed_task (
             SELECT source_prefix as source,
                    date,
                    id,
                    title,
                    category
              FROM task_history_recat
             WHERE status = '"resolved"'
               AND date = daterow.date
               AND source = source_prefix
               AND id NOT IN (SELECT id
                                FROM task_history
                               WHERE status = '"resolved"'
                                 AND source = source_prefix
                                 AND date = daterow.date - interval '1 day' )
             );
    END LOOP;

    RETURN;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION backlog_query (
       source_prefix varchar(6),
       status_input text,
       zoom_input boolean
) RETURNS TABLE(date timestamp, category text, sort_order int, points numeric, count numeric) AS $$
BEGIN
        RETURN QUERY
        SELECT t.date,
               t.category,
               MAX(z.sort_order) as sort_order,
               SUM(t.points)::numeric as points,
               SUM(t.count)::numeric as count
          FROM tall_backlog t, category_list z
         WHERE t.source = source_prefix
           AND z.source = source_prefix
           AND t.source = z.source
           AND t.category = z.category
           AND t.status = status_input
           AND (z.zoom = True OR z.zoom = zoom_input)
         GROUP BY t.date, t.category
         ORDER BY t.date, sort_order;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION calculate_velocities(
    source_prefix varchar(6)
    ) RETURNS void AS $$
DECLARE
  past_dates date[];
  future_dates date[];
  weekday date;
  most_recent_data date;
  weekrow record;
  tranche record;
  weeks_ahead int;
  min_points_vel float;
  avg_points_vel float;
  max_points_vel float;
  min_count_vel float;
  avg_count_vel float;
  max_count_vel float;
  min_points_grow float;
  avg_points_grow float;
  max_points_grow float;
  min_count_grow float;
  avg_count_grow float;
  max_count_grow float;
  threew_max_points_grow float;
  threem_max_points_grow float;
  threew_max_count_grow float;
  threem_max_count_grow float;
  threew_avg_points_grow float;
  threem_avg_points_grow float;
  threew_avg_count_grow float;
  threem_avg_count_grow float;
BEGIN

    DELETE FROM velocity where source = source_prefix;

    -- Select dates at one week multiples of today
    -- from 6 months ago (enough for full quarter plus 3 mo before for
    -- historical baseline) to 3 months forward (full quarter)
    -- TODO: may need to restore a one-day offset to match 
    -- this line in phlogiston.py:
    -- working_date += datetime.timedelta(days=1)

    SELECT ARRAY(
    SELECT date_trunc('day', dd)::date
      INTO past_dates
      FROM GENERATE_SERIES
           (now() - interval '26 weeks',
            now(),
            '1 week'::interval) dd
    );

    SELECT ARRAY(
    SELECT date_trunc('day', dd)::date
      INTO future_dates
      FROM GENERATE_SERIES
           (now(),
            now() + interval '13 weeks',
            '1 week'::interval) dd
    );

    -- load historical data into velocity
    INSERT INTO velocity (
    SELECT source,
           category,
           date,
           SUM(points) AS points_total,
           SUM(count) AS count_total
      FROM tall_backlog
     WHERE date = ANY (past_dates)
       AND source = source_prefix
     GROUP BY date, source, category);

    -- load more historical data into velocity
    UPDATE velocity v
       SET points_resolved = sum_points_resolved,
           count_resolved = sum_count_resolved
      FROM (SELECT source,
                   date,
                   category,
                   SUM(points) AS sum_points_resolved,
                   SUM(count) AS sum_count_resolved
              FROM tall_backlog
             WHERE status = '"resolved"'
               AND source = source_prefix
             GROUP BY source, date, category) as t
     WHERE t.date = v.date
       AND t.category = v.category
       AND t.source = v.source
       AND v.source = source_prefix;

    -- calculate deltas for historical data
    UPDATE velocity
       SET delta_points_resolved = COALESCE(subq.delta_points_resolved,0),
           delta_count_resolved = COALESCE(subq.delta_count_resolved,0),
           delta_points_total = COALESCE(subq.delta_points_total,0),
           delta_count_total = COALESCE(subq.delta_count_total,0)
      FROM (SELECT source,
                   date,
                   category,
                   count_resolved - lag(count_resolved) OVER
                       (PARTITION BY source, category ORDER BY date) as delta_count_resolved,
                   points_resolved - lag(points_resolved) OVER
                       (PARTITION BY source, category ORDER BY date) as delta_points_resolved,
                   count_total - lag(count_total) OVER
                       (PARTITION BY source, category ORDER BY date) as delta_count_total,
                   points_total - lag(points_total) OVER
                       (PARTITION BY source, category ORDER BY date) as delta_points_total
      FROM velocity
     WHERE source = source_prefix) as subq
     WHERE velocity.source = subq.source
       AND velocity.date = subq.date
       AND velocity.category = subq.category;   

    -- calculate retrocasts and forecasts up to current day
    FOREACH weekday IN ARRAY past_dates
    LOOP
        FOR tranche IN SELECT DISTINCT category
                         FROM tall_backlog
                        WHERE date = weekday
                          AND source = source_prefix
                        ORDER BY category
        LOOP
            SELECT SUM(total::float)/3
              INTO min_points_vel
              FROM (SELECT CASE WHEN delta_points_resolved < 0 THEN 0
                           ELSE delta_points_resolved
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_points_resolved 
                     LIMIT 3) AS x;

            SELECT SUM(delta_points_resolved::float)/3
              INTO max_points_vel
              FROM (SELECT delta_points_resolved
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_points_resolved DESC
                     LIMIT 3) AS x;

            SELECT AVG(delta_points_resolved::float)
              INTO avg_points_vel
              FROM velocity subqv
             WHERE subqv.date > weekday - interval '3 months'
               AND subqv.date <= weekday
               AND subqv.source = source_prefix
               AND subqv.category = tranche.category;

            SELECT SUM(total::float)/3
              INTO threew_max_points_grow
              FROM (SELECT CASE WHEN delta_points_total < 0 THEN 0
                           ELSE delta_points_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 weeks'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_points_total DESC
                     LIMIT 3) AS x;

            SELECT SUM(total::float)/3
              INTO threem_max_points_grow
              FROM (SELECT CASE WHEN delta_points_total < 0 THEN 0
                           ELSE delta_points_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_points_total DESC
                     LIMIT 3) AS x;

            SELECT AVG(total::float)
              INTO threew_avg_points_grow
              FROM (SELECT CASE WHEN delta_points_total < 0 THEN 0
                           ELSE delta_points_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 weeks'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category) AS x;

            SELECT AVG(total::float)
              INTO threem_avg_points_grow
              FROM (SELECT CASE WHEN delta_points_total < 0 THEN 0
                           ELSE delta_points_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category) as x;

            SELECT SUM(total::float)/3 AS min_count_vel
              INTO min_count_vel
              FROM (SELECT CASE WHEN delta_count_resolved < 0 THEN 0
                           ELSE delta_count_resolved
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_count_resolved 
                     LIMIT 3) AS x;

            SELECT SUM(delta_count_resolved::float)/3 AS max_count_vel
              INTO max_count_vel
              FROM (SELECT delta_count_resolved
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_count_resolved DESC
                     LIMIT 3) AS x;

            SELECT AVG(delta_count_resolved::float)
              INTO avg_count_vel
              FROM velocity subqv
             WHERE subqv.date > weekday - interval '3 months'
               AND subqv.date <= weekday
               AND subqv.source = source_prefix
               AND subqv.category = tranche.category;

            SELECT SUM(total::float)/3
              INTO threew_max_count_grow
              FROM (SELECT CASE WHEN delta_count_total < 0 THEN 0
                           ELSE delta_count_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 weeks'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_count_total DESC
                     LIMIT 3) AS x;

            SELECT SUM(total::float)/3
              INTO threem_max_count_grow
              FROM (SELECT CASE WHEN delta_count_total < 0 THEN 0
                           ELSE delta_count_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category
                     ORDER BY subqv.delta_count_total DESC
                     LIMIT 3) AS x;

            SELECT AVG(total::float)
              INTO threew_avg_count_grow
              FROM (SELECT CASE WHEN delta_count_total < 0 THEN 0
                           ELSE delta_count_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 weeks'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category) AS x;

            SELECT AVG(total::float)
              INTO threem_avg_count_grow
              FROM (SELECT CASE WHEN delta_count_total < 0 THEN 0
                           ELSE delta_count_total
                           END AS total
                      FROM velocity subqv
                     WHERE subqv.date > weekday - interval '3 months'
                       AND subqv.date <= weekday
                       AND subqv.source = source_prefix
                       AND subqv.category = tranche.category) as x;

            SELECT threem_avg_points_grow
              INTO avg_points_grow;

            SELECT (threem_avg_points_grow + threem_max_points_grow)/2
              INTO max_points_grow;

            SELECT threem_avg_count_grow
              INTO avg_count_grow;

            SELECT (threem_avg_count_grow + threem_max_count_grow)/2
              INTO max_count_grow;

            UPDATE velocity
               SET pes_points_vel = min_points_vel,
                   nom_points_vel = avg_points_vel,
                   opt_points_vel = max_points_vel,
                   pes_count_vel = min_count_vel,
                   nom_count_vel = avg_count_vel,
                   opt_count_vel = max_count_vel,
                   opt_points_total_growrate = 0,
                   nom_points_total_growrate = avg_points_grow,
                   pes_points_total_growrate = max_points_grow,
                   opt_count_total_growrate = 0,
                   nom_count_total_growrate = avg_count_grow,
                   pes_count_total_growrate = max_count_grow,
                   threem_max_points_growrate = threem_max_points_grow,
                   threew_max_points_growrate = threew_max_points_grow,
                   threem_max_count_growrate = threem_max_count_grow,
                   threew_max_count_growrate = threew_max_count_grow
             WHERE source = source_prefix
               AND category = tranche.category
               AND date = weekday;

        END LOOP;
    END LOOP;

    -- generate actual forecast in weeks for all historical data
    -- (for everything but the current week, this is technically a retrocast)
    -- Forecast backlog growth is subtracted from forecast velocity to determine
    -- projected velocity used in calculations
    -- minimum velocity is set to 1 in these calculations

    UPDATE velocity
       SET pes_points_fore = round((points_total - points_resolved)::float /
                                    GREATEST((pes_points_vel - pes_points_total_growrate),1)),
           nom_points_fore = round((points_total - points_resolved)::float /
                                    GREATEST((nom_points_vel - nom_points_total_growrate),1)),
           opt_points_fore = round((points_total - points_resolved)::float /
                                    GREATEST((opt_points_vel - opt_points_total_growrate),1))
     WHERE source = source_prefix
       AND points_resolved < points_total;

    UPDATE velocity
       SET pes_count_fore = round((count_total - count_resolved)::float /
                                    GREATEST((pes_count_vel - pes_count_total_growrate),1)),
           nom_count_fore = round((count_total - count_resolved)::float /
                                    GREATEST((nom_count_vel - nom_count_total_growrate),1)),
           opt_count_fore = round((count_total - count_resolved)::float /
                                    GREATEST((opt_count_vel - opt_count_total_growrate),1))
     WHERE source = source_prefix
       AND count_resolved < count_total;
       
    -- convert # of weeks in future to specific date
    
    UPDATE velocity
       SET pes_points_date = date_trunc('day', date + (pes_points_fore * interval '1 week')),
           nom_points_date = date_trunc('day', date + (nom_points_fore * interval '1 week')),
           opt_points_date = date_trunc('day', date + (opt_points_fore * interval '1 week')),
           pes_count_date = date_trunc('day', date + (pes_count_fore * interval '1 week')),
           nom_count_date = date_trunc('day', date + (nom_count_fore * interval '1 week')),
           opt_count_date = date_trunc('day', date + (opt_count_fore * interval '1 week'))
     WHERE source = source_prefix;

    -- calculate future projections based on today's forecasts
    -- include today to get zero-based forecast viz lines

    FOR tranche IN SELECT DISTINCT category
                     FROM tall_backlog
                    WHERE source = source_prefix
                    ORDER BY category
    LOOP
        SELECT MAX(date)
          INTO most_recent_data
          FROM velocity
         WHERE source = source_prefix
           AND category = tranche.category
           AND date < now();

        FOREACH weekday IN ARRAY future_dates
        LOOP
            weeks_ahead := EXTRACT(EPOCH FROM date_trunc('day', weekday) - date_trunc('day', now())) / 604800;
            INSERT INTO velocity (source, category, date,
                   pes_points_growviz, nom_points_growviz, opt_points_growviz,
                   pes_count_growviz, nom_count_growviz, opt_count_growviz,
                   pes_points_velviz, nom_points_velviz, opt_points_velviz,
                   pes_count_velviz, nom_count_velviz, opt_count_velviz) (
            SELECT source, category, weekday,
                   points_total + (pes_points_total_growrate * weeks_ahead),
                   points_total + (nom_points_total_growrate * weeks_ahead),
                   points_total + (opt_points_total_growrate * weeks_ahead),
                   count_total + (pes_count_total_growrate * weeks_ahead),
                   count_total + (nom_count_total_growrate * weeks_ahead),
                   count_total + (opt_count_total_growrate * weeks_ahead),
                   points_resolved + (pes_points_vel * weeks_ahead),
                   points_resolved + (nom_points_vel * weeks_ahead),
                   points_resolved + (opt_points_vel * weeks_ahead),
                   count_resolved + (pes_count_vel * weeks_ahead),
                   count_resolved + (nom_count_vel * weeks_ahead),
                   count_resolved + (opt_count_vel * weeks_ahead)
              FROM velocity
             WHERE source = source_prefix
               AND category = tranche.category
               AND date = most_recent_data);

        END LOOP;
    END LOOP;

    RETURN;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION set_category_retroactive(
    source_prefix varchar(6)
    ) RETURNS void AS $$
BEGIN

    UPDATE task_history_recat t
       SET category = t0.category
      FROM task_history_recat t0
     WHERE t0.date = (SELECT MAX(date)
                        FROM task_history_recat
                       WHERE source = source_prefix)
       AND t0.source = source_prefix
       AND t.source = source_prefix
       AND t0.id = t.id;

    RETURN;
END;
$$ LANGUAGE plpgsql;
