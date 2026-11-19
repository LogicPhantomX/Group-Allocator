-- CSC Class 28 Group Allocation: Supabase migration
-- Run this AFTER the earlier setup and registration/admin SQL already completed.
-- The admin reset clears old assignments and slots, but preserves registrations.

-- 1) Password hashing support
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- 2) Add a private password hash to registrations
ALTER TABLE public.student_registrations
ADD COLUMN IF NOT EXISTS access_password_hash TEXT;

-- 3) Link allocations to matric numbers. Existing rows remain unchanged.
ALTER TABLE public.assignments
ADD COLUMN IF NOT EXISTS matric_number TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS assignments_round_matric_unique
ON public.assignments (
  round_no,
  UPPER(REGEXP_REPLACE(TRIM(matric_number), '[[:space:]]+', '', 'g'))
)
WHERE matric_number IS NOT NULL;

-- The old public assignment listing contains device_id. The website will now
-- use get_public_board() to receive only names, groups and slot codes.
REVOKE SELECT ON public.assignments FROM anon, authenticated;

-- 4) Remove the old two-argument registration function so a registration
-- cannot bypass the new private-password requirement.
DROP FUNCTION IF EXISTS public.register_student(TEXT, TEXT);

-- 5) Student self-registration. Password is hashed with bcrypt (pgcrypto).
CREATE OR REPLACE FUNCTION public.register_student(
  p_full_name TEXT,
  p_matric_number TEXT,
  p_access_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_name TEXT := REGEXP_REPLACE(TRIM(p_full_name), '\s+', ' ', 'g');
  v_matric TEXT := UPPER(REGEXP_REPLACE(TRIM(p_matric_number), '[[:space:]]+', '', 'g'));
BEGIN
  IF v_name IS NULL OR char_length(v_name) < 2 OR char_length(v_name) > 120 THEN
    RAISE EXCEPTION 'Enter a valid full name.';
  END IF;
  IF v_matric IS NULL OR v_matric !~ '^[0-9]{10}$' THEN
    RAISE EXCEPTION 'Matriculation number must contain exactly 10 digits.';
  END IF;
  IF p_access_password IS NULL OR char_length(p_access_password) < 8 THEN
    RAISE EXCEPTION 'Your private access password must contain at least 8 characters.';
  END IF;

  INSERT INTO public.student_registrations (
    full_name, matric_number, status, access_password_hash
  ) VALUES (
    v_name, v_matric, 'pending', crypt(p_access_password, gen_salt('bf'))
  );

  RETURN jsonb_build_object(
    'success', true,
    'status', 'pending',
    'message', 'Registration submitted. Await administrator approval.'
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'This matriculation number has already been registered.'
    );
END;
$$;

-- 6) Student allocation. Checks approved registration + private password,
-- locks the allocation state and slot, and returns an existing allocation
-- if the student has already drawn in this round.
CREATE OR REPLACE FUNCTION public.roll_group_by_matric(
  p_matric_number TEXT,
  p_access_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_matric TEXT := UPPER(REGEXP_REPLACE(TRIM(p_matric_number), '[[:space:]]+', '', 'g'));
  v_registration public.student_registrations%ROWTYPE;
  v_round INTEGER;
  v_remaining INTEGER;
  v_existing RECORD;
  v_slot RECORD;
BEGIN
  IF v_matric IS NULL OR v_matric !~ '^[0-9]{10}$' OR p_access_password IS NULL THEN
    RAISE EXCEPTION 'Enter your matriculation number and private access password.';
  END IF;

  SELECT * INTO v_registration
  FROM public.student_registrations s
  WHERE UPPER(REGEXP_REPLACE(TRIM(s.matric_number), '[[:space:]]+', '', 'g')) = v_matric
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registration was found for this matriculation number.';
  END IF;

  IF v_registration.access_password_hash IS NULL
     OR crypt(p_access_password, v_registration.access_password_hash) <> v_registration.access_password_hash THEN
    RAISE EXCEPTION 'Incorrect matriculation number or private access password.';
  END IF;

  IF v_registration.status = 'pending' THEN
    RAISE EXCEPTION 'Your registration is still awaiting administrator approval.';
  ELSIF v_registration.status = 'rejected' THEN
    RAISE EXCEPTION 'Your registration was not approved. Please contact the class administrator.';
  END IF;

  SELECT a.round_no, a.remaining_count
  INTO v_round, v_remaining
  FROM public.allocation_state a
  ORDER BY a.id
  LIMIT 1
  FOR UPDATE;

  IF v_round IS NULL THEN
    RAISE EXCEPTION 'Allocation round has not been initialized.';
  END IF;

  SELECT ass.student_name, ass.group_letter, ass.slot_id, ass.matric_number,
         gs.slot_code
  INTO v_existing
  FROM public.assignments ass
  LEFT JOIN public.group_slots gs ON gs.id = ass.slot_id
  WHERE ass.round_no = v_round
    AND UPPER(REGEXP_REPLACE(TRIM(COALESCE(ass.matric_number, '')), '[[:space:]]+', '', 'g')) = v_matric
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'already_allocated', true,
      'student_name', v_existing.student_name,
      'group_letter', v_existing.group_letter,
      'slot_code', v_existing.slot_code
    );
  END IF;

  SELECT gs.id, gs.slot_code, gs.group_letter
  INTO v_slot
  FROM public.group_slots gs
  WHERE gs.round_no = v_round AND gs.is_available = TRUE
  ORDER BY random()
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'All 21 slots have been allocated.';
  END IF;

  UPDATE public.group_slots
  SET is_available = FALSE
  WHERE id = v_slot.id;

  INSERT INTO public.assignments (
    round_no, student_name, device_id, slot_id, group_letter, allocated_at, matric_number
  ) VALUES (
    v_round, v_registration.full_name, 'matric:' || v_matric,
    v_slot.id, v_slot.group_letter, NOW(), v_matric
  );

  UPDATE public.allocation_state
  SET remaining_count = GREATEST(remaining_count - 1, 0), updated_at = NOW()
  WHERE round_no = v_round;

  RETURN jsonb_build_object(
    'success', true,
    'already_allocated', false,
    'student_name', v_registration.full_name,
    'group_letter', v_slot.group_letter,
    'slot_code', v_slot.slot_code
  );
END;
$$;

-- 7) Safe public board: does not expose matric numbers, device IDs or PIN hashes.
CREATE OR REPLACE FUNCTION public.get_public_board()
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'round_no', st.round_no,
    'remaining_count', st.remaining_count,
    'assignments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'student_name', ass.student_name,
        'group_letter', ass.group_letter,
        'slot_code', gs.slot_code
      ) ORDER BY ass.allocated_at)
      FROM public.assignments ass
      LEFT JOIN public.group_slots gs ON gs.id = ass.slot_id
      WHERE ass.round_no = st.round_no
    ), '[]'::jsonb)
  )
  FROM public.allocation_state st
  ORDER BY st.id
  LIMIT 1;
$$;

-- 8) Admin-only reset: clears old allocation data and creates 21 new slots.
CREATE OR REPLACE FUNCTION public.admin_reset_allocation()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old_round INTEGER;
  v_new_round INTEGER;
  v_state_exists BOOLEAN;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Administrator access required.';
  END IF;

  SELECT round_no INTO v_old_round
  FROM public.allocation_state
  ORDER BY id
  LIMIT 1
  FOR UPDATE;

  v_state_exists := FOUND;
  v_new_round := COALESCE(v_old_round, 0) + 1;

  DELETE FROM public.assignments WHERE id IS NOT NULL;
  DELETE FROM public.group_slots WHERE id IS NOT NULL;

  INSERT INTO public.group_slots (round_no, slot_code, group_letter, is_available)
  SELECT v_new_round, group_letter || '-' || slot_number, group_letter, TRUE
  FROM unnest(ARRAY['A','B','C','D','E','F','G']) AS letters(group_letter)
  CROSS JOIN generate_series(1,3) AS numbers(slot_number);

  IF v_state_exists THEN
    UPDATE public.allocation_state
    SET round_no = v_new_round, remaining_count = 21, updated_at = NOW();
  ELSE
    INSERT INTO public.allocation_state (round_no, remaining_count, updated_at)
    VALUES (v_new_round, 21, NOW());
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'round_no', v_new_round,
    'message', 'A new allocation round has started. Previous allocations were cleared; registrations were kept.'
  );
END;
$$;

-- 9) Admin-only export of current-round assignments, including matric numbers.
CREATE OR REPLACE FUNCTION public.admin_export_allocations()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_round INTEGER;
  v_assignments JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Administrator access required.';
  END IF;

  SELECT round_no INTO v_round
  FROM public.allocation_state
  ORDER BY id
  LIMIT 1;

  IF v_round IS NULL THEN
    RAISE EXCEPTION 'Allocation state has not been initialized.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'student_name', ass.student_name,
    'matric_number', ass.matric_number,
    'group_letter', ass.group_letter,
    'slot_code', gs.slot_code,
    'allocated_at', ass.allocated_at
  ) ORDER BY ass.group_letter, gs.slot_code), '[]'::jsonb)
  INTO v_assignments
  FROM public.assignments ass
  LEFT JOIN public.group_slots gs ON gs.id = ass.slot_id
  WHERE ass.round_no = v_round;

  RETURN jsonb_build_object(
    'round_no', v_round,
    'assignments', v_assignments
  );
END;
$$;

-- 10) Least-privilege function permissions
REVOKE ALL ON FUNCTION public.register_student(TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.roll_group_by_matric(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_board() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reset_allocation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_export_allocations() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.register_student(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.roll_group_by_matric(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_board() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_allocation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_export_allocations() TO authenticated;

-- Existing admin_list_registrations and admin_review_registration functions
-- remain in place from the previous step.
