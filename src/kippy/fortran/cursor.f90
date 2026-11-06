! kippy - Kippenhahn diagram viewer
! Copyright (C) 2026 the kippy authors (see AUTHORS)
!
! This file is part of kippy.
!
! kippy is free software: you can redistribute it and/or modify
! it under the terms of the GNU Lesser General Public License as
! published by the Free Software Foundation, either version 3 of the
! License, or (at your option) any later version.
!
! kippy is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
! FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
! License for more details.
!
! You should have received a copy of the GNU Lesser General Public
! License along with kippy. If not, see <https://www.gnu.org/licenses/>.

! cursor.f90 -- cursor mode and window input of the kipp renderer
module cursor
   !! Cursor mode and window input.
   !!
   !! - `kipp_interact` runs cursor mode, one `kipp_action` per key press or click in the /xw window.
   !! - `kipp_action` applies one cursor key at a world position.
   !!   The keys zoom, pan, select ranges, save snapshots, toggle overlays and undo view changes.
   !! - `kipp_wait_input` blocks at the REPL prompt until stdin or the plot window has input.
   !! - `kipp_window_center` gives the view centre, the default position of a scripted key.
   !! - `print_cell` prints the model and zone cell under the cursor.
   !!
   !! The "view history" `views` holds the view before each view change, for the `u` key.
   !! `clear_views` empties it.
   !!
   !! kipp.f90 re-exports `kipp_interact`, `kipp_action`, `kipp_wait_input` and `kipp_window_center`.
   !! Its `kipp_rebuild` calls `clear_views` after an axis change.
   !! The keys write the view limits and display toggles of `st` in kipp_state.f90, then render through draw.f90.
   !! This module holds the view history and the snapshot counter.

   use, intrinsic :: iso_fortran_env, only: output_unit
   use iso_c_binding, only: c_int
   use typedef, only: int32, real64
   use convdata, only: data, FIELD_NBINS, field_names, field_vmin, field_vmax, field_vpos, field_log, &
                       RADIATIVE, NCONVTYPES
   use units, only: unit_id, UFAC
   use kipp_state, only: st, nmodels, xedge
   use coords, only: kipp_autoscale, yscale, xtrans, ytrans2, inv_x, inv_y, mbound, coord_at, bisect_le
   use layers, only: type_of, level_mins, layer_of_cfield, field_of_cfield, field_layer_len, &
                     get_layer, get_field_buf
   use draw, only: kipp_render, kipp_save
   use giza

   implicit none
   private

   public :: kipp_interact, kipp_wait_input, kipp_action, kipp_window_center, clear_views

   interface
      function c_getpid() bind(C, name='getpid') result(pid)
         !! Return the process id, with POSIX `getpid`.
         !!
         !! The temporary PNG of the `p` clipboard copy is named after it.
         import :: c_int
         integer(c_int) :: pid
      end function c_getpid
      function c_isatty(fd) bind(C, name='isatty') result(tty)
         !! Test a file descriptor for a terminal, with POSIX `isatty`.
         !!
         !! The result is nonzero for a terminal.
         import :: c_int
         integer(c_int), value :: fd
            !! File descriptor to test.
         integer(c_int) :: tty
      end function c_isatty
   end interface

   ! characters that are delivered by the giza /xw driver for mouse events
   ! (see giza-shared.h: LEFT/MIDDLE/RIGHT click, scroll wheel, Esc)
   character(len=1), parameter :: K_LCLICK = 'A'
      !! Left click.
   character(len=1), parameter :: K_MCLICK = 'D'
      !! Middle click.
   character(len=1), parameter :: K_RCLICK = 'X'
      !! Right click.
   character(len=1), parameter :: K_SCRUP = achar(21)
      !! Scroll up.
   character(len=1), parameter :: K_SCRDN = achar(4)
      !! Scroll down.
   character(len=1), parameter :: K_SCRLT = achar(12)
      !! Scroll left.
   character(len=1), parameter :: K_SCRRT = achar(18)
      !! Scroll right.
   character(len=1), parameter :: K_ESC = achar(27)
      !! Esc key.
   character(len=1), parameter :: K_CTRLC = achar(3)
      !! Ctrl-C.

   integer(int32) :: nsnap = 0
      !! Number of the last numbered snapshot saved from cursor mode.

   type :: view_t
      !! One view of the view history.
      !!
      !! Limits are kept in seconds (or model number) and cgs,
      !! because the auto time unit rescales `st%xmin` and `st%xmax`.
      real(real64) :: lim(4)
         !! View limits, xmin, xmax, ymin and ymax.
      logical      :: xauto, yauto
         !! Auto-scale flags of x and y in this view.
   end type view_t
   type(view_t), allocatable :: views(:)
      !! View history for `u`, oldest first.

contains

   subroutine kipp_interact()
      !! Run cursor mode in the /xw window.
      !!
      !! Each key press or mouse click acts at the world coordinates giza reports for the cursor,
      !! so keys act "where the mouse is".
      !! Control returns to the REPL on `q`, Esc or Ctrl-C.
      real(real64) :: x, y
      character(len=1) :: ch
      integer :: ierr
      logical :: done

      if (.not. st%interactive) then
         print '(a)', '[kipp] cursor mode needs an interactive /xw window'
         return
      end if
      if (st%devid <= 0) call kipp_render()
      if (st%devid <= 0) return
      if (.not. giza_device_has_cursor()) then
         print '(a)', '[kipp] device has no cursor'
         return
      end if

      call cursor_help()
      do
         x = 0.d0; y = 0.d0; ch = ' '
         ierr = giza_get_key_press(x, y, ch)
         if (ierr /= 0) exit
         call kipp_action(ch, x, y, done)
         if (done) exit
      end do
   end subroutine kipp_interact

   integer function kipp_wait_input()
      !! Block at the REPL prompt until stdin or the plot window has input.
      !!
      !! The result is 0 for stdin input and 1 for a click in the plot window.
      !! It is -1 when the window's close button is pressed, now or in cursor mode.
      !! Only a terminal stdin is watched.
      !! gfortran buffers piped stdin, so a poll could miss lines it has already read.
      kipp_wait_input = 0
      if (.not. st%interactive .or. st%devid <= 0) return
      if (c_isatty(0_c_int) == 0) return
      flush (output_unit)
      call giza_select_device(st%devid)
      kipp_wait_input = giza_wait_fd_or_click(0_c_int)
   end function kipp_wait_input

   subroutine kipp_action(ch, x, y, done)
      !! Apply one cursor key `ch` at world position (`x`, `y`).
      !!
      !! World coordinates are those of coords.f90, as giza reports them for the cursor.
      !! Shared by the interactive loop and the scripted REPL `key` command (`KIPP_SCRIPT`).
      !! Each view change except `u` pushes the old view onto the view history.
      ! Arguments
      character(len=1), intent(in) :: ch
         !! Key or mouse event character, as giza reports it.
      real(real64), intent(in) :: x
         !! Cursor x, in world coordinates.
      real(real64), intent(in) :: y
         !! Cursor y, in world coordinates.
      logical, intent(out) :: done
         !! Set when `ch` asks to leave cursor mode.
      real(real64) :: xa, ya, x2, y2
      character(len=1) :: ch2
      character(len=80) :: snap
      character(len=512) :: cmd
      integer :: ierr, exitstat, cmdstat, tmpunit
      type(view_t) :: old, new

      done = .false.
      xa = x; ya = y
      if (.not. allocated(views)) allocate (views(0))
      old = view_now()
      select case (ch)
      case ('q', K_ESC, K_CTRLC)               ! back to the REPL
         done = .true.
      case (K_LCLICK)                          ! drag-rectangle zoom
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_rectangle, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= K_CTRLC .and. ch2 /= 'q') then
            call set_xrange_w(xa, x2)
            call set_yrange_w(ya, y2)
            call kipp_render()
         end if
      case ('x')                               ! select an x range
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_vertlines, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= K_CTRLC .and. ch2 /= 'q') then
            call set_xrange_w(xa, x2)
            call kipp_render()
         end if
      case ('y')                               ! select a y range
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_horzlines, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= K_CTRLC .and. ch2 /= 'q') then
            call set_yrange_w(ya, y2)
            call kipp_render()
         end if
      case (K_SCRUP, 'z', '+')                 ! zoom in about cursor
         call zoom_at(xa, ya, 0.5d0); call kipp_render()
      case (K_SCRDN, K_RCLICK, 'Z', '-')       ! zoom out about cursor
         call zoom_at(xa, ya, 2.0d0); call kipp_render()
      case (K_SCRLT, 'h')
         call pan_frac(-0.25d0, 0.d0); call kipp_render()
      case (K_SCRRT, 'l')
         call pan_frac(0.25d0, 0.d0); call kipp_render()
      case ('j')
         call pan_frac(0.d0, -0.25d0); call kipp_render()
      case ('k')
         call pan_frac(0.d0, 0.25d0); call kipp_render()
      case (K_MCLICK, 'c')                     ! centre view on cursor
         call center_at(xa, ya); call kipp_render()
      case ('r', 'a', '0')                     ! reset to full view
         st%xauto = .true.; st%yauto = .true.
         call kipp_autoscale(); call kipp_render()
      case ('s')                               ! numbered png snapshot
         nsnap = nsnap + 1
         write (snap, '(a,a,i4.4)') trim(st%prefix), '_', nsnap
         call kipp_save(trim(snap))
      case ('p')                               ! copy png to clipboard
         write (snap, '(a,i0,a)') '/tmp/kippy-', c_getpid(), '-clip'
         call kipp_save(trim(snap))
         ! the forked clipboard owner must not hold our stdout/stderr: if
         ! those are a pipe it dies when the pipe closes and the copy is lost.
         ! macos pbcopy only takes text, so the png goes to NSPasteboard via jxa
         cmd = "{ wl-copy --type image/png < "//trim(snap)//".png || "// &
               'osascript -l JavaScript -e ''ObjC.import("AppKit"); '// &
               'var pb = $.NSPasteboard.generalPasteboard; pb.clearContents; '// &
               'if (!pb.setDataForType($.NSData.dataWithContentsOfFile("'//trim(snap)//'.png"), '// &
               '$.NSPasteboardTypePNG)) throw "copy failed"'' || '// &
               "xclip -selection clipboard -t image/png -i "//trim(snap)//".png; } "// &
               ">/dev/null 2>&1"
         exitstat = 1
         cmdstat = 1
         call execute_command_line(trim(cmd), wait=.true., exitstat=exitstat, cmdstat=cmdstat)
         if (cmdstat == 0 .and. exitstat == 0) then
            print '(a)', '[kipp] copied png to clipboard'
         else
            print '(a)', '[kipp] could not copy png: wl-copy, osascript and xclip missing or failed'
         end if
         open (newunit=tmpunit, file=trim(snap)//'.png', status='old', iostat=ierr)
         if (ierr == 0) close (tmpunit, status='delete')
      case ('S')                               ! numbered pdf snapshot
         nsnap = nsnap + 1
         write (snap, '(a,a,i4.4)') trim(st%prefix), '_', nsnap
         call kipp_save(trim(snap)//'.pdf')
      case ('g')                               ! toggle the cell/time grid
         st%showgrid = .not. st%showgrid; call kipp_render()
      case ('m')                               ! toggle the model-number strip
         st%showmodels = .not. st%showmodels; call kipp_render()
      case ('v')                               ! print the cell under the cursor
         call print_cell(xa, ya)
      case ('u')                               ! back to the previous view
         if (size(views) == 0) then
            print '(a)', '[kipp] no earlier view'
         else
            call set_view(views(size(views)))
            views = views(:size(views) - 1)
            call kipp_render()
         end if
      case ('?')
         call cursor_help()
      case default
         ! ignore anything else (shift-click, unmapped keys)
      end select
      ! compared after the render, so a cancelled selection or a pan stopped
      ! by clamp_view at the data edge records nothing
      new = view_now()
      if (ch /= 'u' .and. any(new%lim /= old%lim)) views = [views, old]
   end subroutine kipp_action

   function view_now() result(v)
      !! Return the current view as a `view_t`.
      type(view_t) :: v
      real(real64) :: fx
      fx = merge(UFAC(unit_id(st%tunit)), 1.d0, st%xaxis == 'time')
      v%lim = [st%xmin*fx, st%xmax*fx, st%ymin*yscale(), st%ymax*yscale()]
      v%xauto = st%xauto; v%yauto = st%yauto
   end function view_now

   subroutine set_view(v)
      !! Restore a view of the view history.
      ! Arguments
      type(view_t), intent(in) :: v
         !! View to restore.
      real(real64) :: fx
      fx = merge(UFAC(unit_id(st%tunit)), 1.d0, st%xaxis == 'time')
      st%xmin = v%lim(1)/fx; st%xmax = v%lim(2)/fx
      st%ymin = v%lim(3)/yscale(); st%ymax = v%lim(4)/yscale()
      st%xauto = v%xauto; st%yauto = v%yauto
   end subroutine set_view

   subroutine clear_views()
      !! Empty the view history.
      if (allocated(views)) deallocate (views)
   end subroutine clear_views

   subroutine kipp_window_center(cx, cy)
      !! Give the centre of the current view, in world coordinates.
      !!
      !! This is the default position of a scripted key.
      ! Arguments
      real(real64), intent(out) :: cx
         !! x of the view centre.
      real(real64), intent(out) :: cy
         !! y of the view centre.
      cx = 0.5d0*(xtrans(st%xmin) + xtrans(st%xmax))
      cy = 0.5d0*(ytrans2(st%ymin) + ytrans2(st%ymax))
   end subroutine kipp_window_center

   subroutine cursor_help()
      !! Print the cursor key reference.
      print '(a)', 'cursor mode (keys act at the mouse position in the plot window):'
      print '(a)', '  left-click       drag rectangle zoom     x / y  select x / y range'
      print '(a)', '  scroll / z / Z   zoom in / out           right-click  zoom out'
      print '(a)', '  h j k l          pan left down up right  middle-click / c  centre here'
      print '(a)', '  r                reset to full view      s / S  save png / pdf snapshot'
      print '(a)', '  p                copy png to clipboard   g  toggle cell/time grid'
      print '(a)', '  m                toggle model strip      v  print the cell under the cursor'
      print '(a)', '  u                undo the last view change'
      print '(a)', '  ?                this help               q / Esc / Ctrl-C  back to prompt'
   end subroutine cursor_help

   subroutine print_cell(wx, wy)
      !! Print the model and zone cell at world position (`wx`, `wy`).
      !!
      !! The line gives the model, time, zone faces, convection type and the selected colour value as drawn.
      !! A column field prints its bin's value range, since only the bin is stored.
      ! Arguments
      real(real64), intent(in) :: wx
         !! Cursor x, in world coordinates.
      real(real64), intent(in) :: wy
         !! Cursor y, in world coordinates.
      character(len=14), parameter :: TYPE_NAME(0:NCONVTYPES) = [character(len=14) :: &
         'radiative', 'neutral', 'overshoot', 'semiconvective', 'convective', 'thermohaline']
      character(len=256) :: line
      character(len=96) :: cval
      character(len=12) :: s1, s2, sj
      character(len=11) :: ename
      integer(int32) :: i, j, k, nc, t, layer, f, n, lev, gmin, lmin
      integer(int32), allocatable :: vals(:), idxs(:)
      real(real64) :: yc, a, b
      logical :: logscale

      i = bisect_le(xedge, inv_x(wx))
      j = 0; nc = 0; lev = 0
      if (i >= 1 .and. i <= nmodels) then
         nc = data(i)%ncoord
         yc = inv_y(wy)*yscale()
         if (st%yaxis == 'radius') then
            j = bisect_le(data(i)%rncoord(1:nc), yc)
         else
            j = bisect_le(data(i)%xmcoord(1:nc), yc)
         end if
      end if
      if (j < 1 .or. j >= nc) then
         print '(a)', '[kipp] no cell under the cursor'
         return
      end if

      write (line, '(a,i0)') '[kipp] model ', data(i)%ncyc
      if (st%xaxis /= 'model') then
         write (s1, '(es10.3)') data(i)%timesec/UFAC(unit_id(st%tunit))
         line = trim(line)//'  t = '//trim(adjustl(s1))//' '//trim(st%tunit)
      end if
      write (s1, '(es10.3)') coord_at(i, j)/yscale()
      write (s2, '(es10.3)') coord_at(i, j + 1)/yscale()
      write (sj, '(i0)') j
      line = trim(line)//'  zone '//trim(sj)//': '//trim(adjustl(s1))//' .. '// &
             trim(adjustl(s2))//' '//trim(merge(st%runit, st%munit, st%yaxis == 'radius'))

      ! zone k of the convection run-length list spans [mbound(k-1), mbound(k)]
      t = RADIATIVE
      do k = 1, int(data(i)%nconv, int32)
         if (mbound(i, k) > yc) then
            t = type_of(data(i)%yzip(k))
            exit
         end if
      end do
      line = trim(line)//'  '//trim(TYPE_NAME(t))

      ! the colour value at zone j is the step-function entry starting at or below it
      cval = ''
      layer = layer_of_cfield()
      f = field_of_cfield()
      if (layer >= 0) then
         call get_layer(i, layer, vals, idxs, n)
      else if (f > 0) then
         n = field_layer_len(i, f)
         allocate (vals(n), idxs(n))
         call get_field_buf(i, f, vals, idxs, n)
      end if
      if (allocated(vals)) then
         do k = 1, n
            if (idxs(k) > j) exit
            lev = vals(k)
         end do
      end if
      if (layer >= 0) then
         ename = merge('log eps_nuc', 'log eps_nu ', layer /= 2)
         call level_mins(layer, gmin, lmin)
         lmin = max(lmin, gmin)
         if (lev > 0) then
            write (cval, '(a,a,i0,a)') trim(ename), ' = ', gmin + lev - 1, ' (gain)'
         else if (lev < 0) then
            write (cval, '(a,a,i0,a)') trim(ename), ' = ', lmin - lev - 1, ' (loss)'
         else
            cval = ename(5:)//' below the lowest level'
         end if
      else if (f > 0) then
         logscale = field_log(f) .neqv. st%cflip
         if (logscale) then
            a = log10(field_vpos(f)); b = log10(field_vmax(f))
         else
            a = field_vmin(f); b = field_vmax(f)
         end if
         write (s1, '(es10.3)') a + (b - a)*real(lev - 1, real64)/real(FIELD_NBINS, real64)
         write (s2, '(es10.3)') a + (b - a)*real(lev, real64)/real(FIELD_NBINS, real64)
         write (cval, '(a,a,a,i0,a,i0,a)') trim(merge('log ', '    ', logscale))//' '// &
            trim(field_names(f)), ' = '//trim(adjustl(s1))//' .. '//trim(adjustl(s2)), &
            ' (bin ', lev, '/', FIELD_NBINS, ')'
         cval = adjustl(cval)
      end if
      if (len_trim(cval) > 0) line = trim(line)//'  '//trim(cval)
      print '(a)', trim(line)
   end subroutine print_cell

   subroutine set_xrange_w(a, b)
      !! Set the x view limits from two world coordinates, in either order.
      !!
      !! A degenerate selection, such as a double click in place, is ignored.
      ! Arguments
      real(real64), intent(in) :: a
         !! One end of the selection.
      real(real64), intent(in) :: b
         !! Other end of the selection.
      real(real64) :: lo, hi
      lo = min(a, b); hi = max(a, b)
      if (hi <= lo) return
      st%xmin = inv_x(lo); st%xmax = inv_x(hi)
      st%xauto = .false.
   end subroutine set_xrange_w

   subroutine set_yrange_w(a, b)
      !! Set the y view limits from two world coordinates, in either order.
      !!
      !! A degenerate selection is ignored.
      ! Arguments
      real(real64), intent(in) :: a
         !! One end of the selection.
      real(real64), intent(in) :: b
         !! Other end of the selection.
      real(real64) :: lo, hi
      lo = min(a, b); hi = max(a, b)
      if (hi <= lo) return
      st%ymin = inv_y(lo); st%ymax = inv_y(hi)
      st%yauto = .false.
   end subroutine set_yrange_w

   subroutine zoom_at(cx, cy, f)
      !! Rescale both axes by `f` about a world position.
      !!
      !! `f` < 1 zooms in and `f` > 1 zooms out.
      !! The data under the cursor stays put.
      ! Arguments
      real(real64), intent(in) :: cx
         !! x of the fixed point, in world coordinates.
      real(real64), intent(in) :: cy
         !! y of the fixed point, in world coordinates.
      real(real64), intent(in) :: f
         !! Factor applied to the world-space spans.
      real(real64) :: a, b
      a = xtrans(st%xmin); b = xtrans(st%xmax)
      st%xmin = inv_x(cx + (a - cx)*f)
      st%xmax = inv_x(cx + (b - cx)*f)
      a = ytrans2(st%ymin); b = ytrans2(st%ymax)
      st%ymin = inv_y(cy + (a - cy)*f)
      st%ymax = inv_y(cy + (b - cy)*f)
      st%xauto = .false.; st%yauto = .false.
   end subroutine zoom_at

   subroutine pan_frac(fx, fy)
      !! Shift the view by a fraction of the current world-space span.
      ! Arguments
      real(real64), intent(in) :: fx
         !! Shift along x, as a fraction of the x span.
      real(real64), intent(in) :: fy
         !! Shift along y, as a fraction of the y span.
      real(real64) :: a, b, d
      if (fx /= 0.d0) then
         a = xtrans(st%xmin); b = xtrans(st%xmax); d = (b - a)*fx
         st%xmin = inv_x(a + d); st%xmax = inv_x(b + d)
         st%xauto = .false.
      end if
      if (fy /= 0.d0) then
         a = ytrans2(st%ymin); b = ytrans2(st%ymax); d = (b - a)*fy
         st%ymin = inv_y(a + d); st%ymax = inv_y(b + d)
         st%yauto = .false.
      end if
   end subroutine pan_frac

   subroutine center_at(cx, cy)
      !! Pan so a world position becomes the view centre.
      ! Arguments
      real(real64), intent(in) :: cx
         !! x of the new centre, in world coordinates.
      real(real64), intent(in) :: cy
         !! y of the new centre, in world coordinates.
      real(real64) :: a, b, d
      a = xtrans(st%xmin); b = xtrans(st%xmax)
      d = cx - 0.5d0*(a + b)
      st%xmin = inv_x(a + d); st%xmax = inv_x(b + d)
      a = ytrans2(st%ymin); b = ytrans2(st%ymax)
      d = cy - 0.5d0*(a + b)
      st%ymin = inv_y(a + d); st%ymax = inv_y(b + d)
      st%xauto = .false.; st%yauto = .false.
   end subroutine center_at

end module cursor
