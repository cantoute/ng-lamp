" Source: https://vimawesome.com/plugin/nginx-vim

au BufRead,BufNewFile /etc/nginx/*,/usr/local/nginx/conf/* if &ft == '' | setfiletype nginx | endif

