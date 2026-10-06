! convview.f90 -- interactive Kippenhahn viewer
!
! Usage:  ./convview [file.cnv]      (default: convdata.cnv)
!
! Reads commands from stdin and re-renders after each.  Works with an
! interactive /xw window (when $DISPLAY is set) or can write PNG
! snapshots when headless.
!
program convview

   use kipp
   implicit none (type, external)

   character(len=512) :: line
   character(len=64)  :: cmd, a1, a2, a3
   character(len=256) :: fname
   character(len=8)   :: envbuf
   integer :: ios, envlen, envstat
   real(8) :: v1, v2
   logical :: scripted, done

   ! KIPP_SCRIPT enables the hidden `key` command so a script (e.g. a
   ! fifo) can drive cursor-mode actions through the REPL, and skips the
   ! cursor-mode auto-enter so the REPL keeps reading while the /xw
   ! window stays live.  injection guard: off unless explicitly set
   call get_environment_variable('KIPP_SCRIPT', envbuf, envlen, envstat)
   scripted = (envstat == 0 .and. envlen > 0)

   if (command_argument_count() >= 1) then
      call get_command_argument(1, fname)
   else
      fname = 'convdata.cnv'
   end if

   print '(a)', '[convview] loading '//trim(fname)//' ...'
   call kipp_load(trim(fname))
   print '(a,i0,a)', '[convview] ', nmodels, ' models loaded'
   call kipp_choose_device()
   call kipp_render()
   if (.not. scripted) call kipp_interact()   ! cursor mode first when a window is up
   call help()

   do
      write (*, '(a)', advance='no') 'kipp> '
      read (*, '(a)', iostat=ios) line
      if (ios /= 0) exit                       ! EOF / Ctrl-D
      call tokens(line, cmd, a1, a2, a3)
      if (len_trim(cmd) == 0) cycle

      select case (trim(cmd))
      case ('quit', 'q', 'exit')
         exit
      case ('help', 'h', '?')
         call help()
      case ('redraw', 'r')
         call kipp_render()
      case ('cursor', 'i', 'interact')
         call kipp_interact()
      case ('reset')
         st%xauto = .true.; st%yauto = .true.
         call kipp_autoscale(); call kipp_render()
      case ('xlim')
         if (rd2(a1, a2, v1, v2)) then
            st%xmin = v1; st%xmax = v2; st%xauto = .false.; call kipp_render()
         end if
      case ('ylim')
         if (rd2(a1, a2, v1, v2)) then
            st%ymin = v1; st%ymax = v2; st%yauto = .false.; call kipp_render()
         end if
      case ('xscale')
         st%xlog = (trim(a1) == 'log')
         call kipp_autoscale(); call kipp_render()
      case ('yscale')
         st%ylog = (trim(a1) == 'log')
         call kipp_autoscale(); call kipp_render()
      case ('xaxis')
         if (trim(a1) == 'time' .or. trim(a1) == 'model') then
            st%xaxis = a1; st%xauto = .true.
            call kipp_rebuild(); call kipp_autoscale(); call kipp_render()
         else
            print *, 'xaxis: time|model'
         end if
      case ('yaxis')
         if (trim(a1) == 'mass' .or. trim(a1) == 'radius') then
            st%yaxis = a1; st%yauto = .true.
            call kipp_rebuild(); call kipp_autoscale(); call kipp_render()
         else
            print *, 'yaxis: mass|radius'
         end if
      case ('units')
         st%ysolar = (trim(a1) == 'solar' .or. trim(a1) == 'msun' .or. &
                      trim(a1) == 'rsun')
         st%yauto = .true.; call kipp_autoscale(); call kipp_render()
      case ('color', 'colour')
         if (len_trim(a1) > 0) st%cfield = a1
         call kipp_render()
      case ('cmap', 'colormap', 'colourmap')
         select case (trim(a1))
         case ('teal', 'viridis', 'blue', 'gray', 'grey')
            st%cmap = a1; call kipp_render()
         case default
            print *, 'cmap teal|viridis|blue|gray'
         end select
      case ('models')
         st%showmodels = (trim(a1) == 'on')
         call kipp_render()
      case ('fields', 'columns')
         call kipp_list_fields()
      case ('save')
         if (len_trim(a1) > 0) then
            call kipp_save(trim(a1))
         else
            print *, 'save <file.png|file.pdf>'
         end if
      case ('key')
         ! scripted cursor-mode action; hidden from help, accepted only
         ! when KIPP_SCRIPT is set (position defaults to the view centre)
         if (.not. scripted) then
            print *, 'unknown command: ', trim(cmd), '   (try help)'
         else if (len_trim(a1) == 0) then
            print *, 'key <char> [x y]'
         else
            if (len_trim(a2) > 0 .or. len_trim(a3) > 0) then
               if (.not. rd2(a2, a3, v1, v2)) cycle
            else
               call kipp_window_center(v1, v2)
            end if
            call kipp_action(a1(1:1), v1, v2, done)
         end if
      case default
         print *, 'unknown command: ', trim(cmd), '   (try help)'
      end select
   end do

   call kipp_close()
   print '(a)', '[convview] bye'

contains

   ! split a line into up to four whitespace-separated tokens
   subroutine tokens(s, t0, t1, t2, t3)
      character(len=*), intent(in)  :: s
      character(len=*), intent(out) :: t0, t1, t2, t3
      character(len=len(s)) :: buf
      t0 = ''; t1 = ''; t2 = ''; t3 = ''
      buf = adjustl(s)
      call pop(buf, t0)
      call pop(buf, t1)
      call pop(buf, t2)
      call pop(buf, t3)
   end subroutine tokens

   subroutine pop(buf, tok)
      character(len=*), intent(inout) :: buf
      character(len=*), intent(out)   :: tok
      integer :: p
      buf = adjustl(buf)
      p = index(buf, ' ')
      if (p <= 1) then
         tok = trim(buf); buf = ''
      else
         tok = buf(1:p - 1); buf = buf(p:)
      end if
   end subroutine pop

   logical function rd2(a, b, x, y)
      character(len=*), intent(in) :: a, b
      real(8), intent(out) :: x, y
      integer :: e1, e2
      rd2 = .false.
      read (a, *, iostat=e1) x
      read (b, *, iostat=e2) y
      if (e1 /= 0 .or. e2 /= 0) then
         print *, 'need two numbers'
         return
      end if
      rd2 = .true.
   end function rd2

   subroutine help()
      print '(a)', 'commands:'
      print '(a)', '  xlim <min> <max>      ylim <min> <max>'
      print '(a)', '  xscale lin|log        yscale lin|log'
      print '(a)', '  xaxis time|model      yaxis mass|radius      units solar|cgs'
      print '(a)', '  color convtype|epsnuc|neu|<column>   fields  (list columns)'
      print '(a)', '  cmap teal|viridis|blue|gray   (colour-field colormap)'
      print '(a)', '  models on|off'
      print '(a)', '  cursor (i)            interactive zoom/pan on the plot window'
      print '(a)', '  reset   redraw   save <file.png|file.pdf>   help   quit'
   end subroutine help

end program convview
