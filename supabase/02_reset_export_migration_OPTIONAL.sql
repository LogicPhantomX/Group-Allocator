-- CSC Class 28: Clean restart + grouped Excel/Word report export
-- Run this once in Supabase SQL Editor. This preserves student registrations
-- and admin_users, clears allocation test/current data, and restarts Round 1.

CREATE OR REPLACE FUNCTION public.admin_reset_allocation()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_state_rows INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.admin_users au
    WHERE au.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Administrator access required.';
  END IF;

  -- Remove allocations first to avoid slot foreign-key conflicts.
  DELETE FROM public.assignments;

  -- Clear all prior slot rows, then rebuild the fixed 21-slot inventory.
  DELETE FROM public.group_slots;

  INSERT INTO public.group_slots (round_no, slot_code, group_letter, is_available)
  SELECT
    1,
    group_letter || '-' || slot_number,
    group_letter,
    TRUE
  FROM unnest(ARRAY['A','B','C','D','E','F','G']) AS groups(group_letter)
  CROSS JOIN generate_series(1,3) AS slots(slot_number);

  -- Keep the allocation_state row(s), never delete or recreate them.
  UPDATE public.allocation_state
  SET round_no = 1,
      remaining_count = 21,
      updated_at = NOW();

  GET DIAGNOSTICS v_state_rows = ROW_COUNT;
  IF v_state_rows = 0 THEN
    RAISE EXCEPTION 'allocation_state is empty. Initialize its existing state row first; no state row was deleted.';
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'round_no', 1,
    'remaining_count', 21,
    'message', 'Allocation fully restarted at Round 1. All 21 slots are available. Student registrations and administrator accounts were preserved.'
  );
END;
$$;

-- Admin-only report export. The website uses this RPC for both XLSX and DOCX.
CREATE OR REPLACE FUNCTION public.admin_export_allocations()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_round INTEGER;
  v_rows JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.admin_users au
    WHERE au.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Administrator access required.';
  END IF;

  SELECT round_no
  INTO v_round
  FROM public.allocation_state
  ORDER BY id
  LIMIT 1;

  IF v_round IS NULL THEN
    RAISE EXCEPTION 'Allocation state has not been initialized.';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'student_name', ass.student_name,
        'matric_number', ass.matric_number,
        'group_letter', ass.group_letter,
        'slot_code', gs.slot_code,
        'allocated_at', ass.allocated_at
      )
      ORDER BY ass.group_letter, gs.slot_code, ass.student_name
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.assignments ass
  LEFT JOIN public.group_slots gs ON gs.id = ass.slot_id
  WHERE ass.round_no = v_round;

  RETURN jsonb_build_object(
    'success', TRUE,
    'round_no', v_round,
    'generated_at', NOW(),
    'assignments', v_rows
  );
END;
$$;

-- Permissions
REVOKE ALL ON FUNCTION public.admin_reset_allocation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_export_allocations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reset_allocation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_export_allocations() TO authenticated;
