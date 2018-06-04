use Test::More;

use GD::Image;

local $TODO = 'This fails with libgd2 2.036 in wheezy';
ok(GD::Image->new('t/data/nordkapp_to.jpg'), 'Able to load problematic JPG');
#ok(GD::Image->new('t/data/vannings980.jpg'), 'Able to load problematic JPG');

done_testing;
